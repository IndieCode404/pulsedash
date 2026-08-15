/*==============================================================================
  DBADash  |  10 - Alerting (evaluation + history + Database Mail sender)
  ----------------------------------------------------------------------------
  usp_Evaluate_Alerts scans the rpt.* views, records ONE active row per distinct
  problem in mon.AlertHistory (so you don't get re-spammed every 15 min), and
  auto-resolves anything that has cleared. usp_Send_Alert_Email emails whatever
  is active-and-not-yet-notified via SQL Server Database Mail.

  Prefer SMTP / no Database Mail? Use deploy\Send-Alerts.ps1 instead - it reads
  rpt.ActiveAlerts and sends over plain SMTP. Both mark NotifiedAt so they don't
  double-send.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('mon.AlertHistory') IS NULL
CREATE TABLE mon.AlertHistory
(
    AlertID    BIGINT IDENTITY(1,1) PRIMARY KEY,
    AlertKey   NVARCHAR(300) NOT NULL,     -- stable id for a condition (dedup key)
    Category   VARCHAR(20)   NOT NULL,     -- AG | Lag | Disk | Cost
    Severity   VARCHAR(10)   NOT NULL,     -- WARN | CRIT
    ServerName SYSNAME       NULL,
    Message    NVARCHAR(600) NOT NULL,
    FirstSeen  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    LastSeen   DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    NotifiedAt DATETIME2(0)  NULL,
    Resolved   BIT           NOT NULL DEFAULT 0,
    ResolvedAt DATETIME2(0)  NULL
);
GO
-- One ACTIVE alert per key (resolved history rows are exempt).
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_AlertHistory_Active' AND object_id=OBJECT_ID('mon.AlertHistory'))
CREATE UNIQUE INDEX UX_AlertHistory_Active ON mon.AlertHistory (AlertKey) WHERE Resolved = 0;
GO

/*---------------------------------------------------------------------------
  cfg.usp_Evaluate_Alerts  -  refresh the active-alert set from the rpt views.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE cfg.usp_Evaluate_Alerts
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #cur (AlertKey NVARCHAR(300), Category VARCHAR(20), Severity VARCHAR(10),
                       ServerName SYSNAME NULL, Message NVARCHAR(600));

    INSERT #cur
    SELECT CONCAT('Disk|',ServerName,'|',VolumeName), 'Disk', Severity, ServerName,
           CONCAT(ServerName,' ',VolumeName,' at ',UsedPct,'% - full in ',
                  ISNULL(CAST(DaysToFull AS VARCHAR(10)),'?'),' days (add +',
                  ISNULL(CAST(RecommendedAddGB AS VARCHAR(10)),'?'),' GB)')
    FROM rpt.DiskForecast WHERE Severity IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('AG|',AGName,'|',DatabaseName,'|',ReplicaServer), 'AG', Status, ReplicaServer,
           CONCAT('AG ',AGName,' / ',DatabaseName,' on ',ReplicaServer,' is ',SyncState,' / ',SyncHealth)
    FROM rpt.AGSyncStatus WHERE Status IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('Lag|',ServerName,'|',ObjectName), 'Lag', Status, ServerName,
           CONCAT(Platform,' ',ObjectName,' lag = ',ISNULL(CAST(LagSeconds AS VARCHAR(20)),'?'),'s')
    FROM rpt.DataLag WHERE Status IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('Cost|',ServerName,'|',MetricName,'|',ObservedDay), 'Cost', Severity, ServerName,
           CONCAT('Cost spike: ',MetricName,' = ',Value,' (',PctAboveBaseline,'% over baseline)')
    FROM rpt.CostAnomaly WHERE ObservedDay >= CAST(SYSUTCDATETIME() AS DATE);

    -- upsert active alerts (keep FirstSeen, refresh Severity/Message/LastSeen)
    MERGE mon.AlertHistory AS t
    USING #cur AS s ON t.AlertKey = s.AlertKey AND t.Resolved = 0
    WHEN MATCHED THEN UPDATE SET
        t.Severity = s.Severity, t.Message = s.Message, t.LastSeen = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (AlertKey, Category, Severity, ServerName, Message)
        VALUES (s.AlertKey, s.Category, s.Severity, s.ServerName, s.Message);

    -- auto-resolve anything that has cleared
    UPDATE t SET Resolved = 1, ResolvedAt = SYSUTCDATETIME()
    FROM mon.AlertHistory t
    WHERE t.Resolved = 0
      AND NOT EXISTS (SELECT 1 FROM #cur c WHERE c.AlertKey = t.AlertKey);

    SELECT ActiveAlerts = (SELECT COUNT(*) FROM mon.AlertHistory WHERE Resolved = 0);
END;
GO

/*---------------------------------------------------------------------------
  rpt.ActiveAlerts  -  current alerts, routed to the app owner's email if known.
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.ActiveAlerts
AS
SELECT a.AlertID, a.Category, a.Severity, a.ServerName, a.Message,
       a.FirstSeen, a.LastSeen, a.NotifiedAt,
       Owner      = o.PrimaryOwner,
       OwnerEmail = o.Email
FROM mon.AlertHistory a
OUTER APPLY (SELECT TOP (1) PrimaryOwner, Email FROM cfg.AppOwners ao
             WHERE ao.ServerName = a.ServerName ORDER BY Criticality) o
WHERE a.Resolved = 0;
GO

/*---------------------------------------------------------------------------
  cfg.usp_Send_Alert_Email  -  email active/un-notified alerts via Database Mail.
  Requires Database Mail set up + a mail profile. @Recipients is ';'-separated.
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE cfg.usp_Send_Alert_Email
    @ProfileName SYSNAME,
    @Recipients  VARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n INT = (SELECT COUNT(*) FROM mon.AlertHistory WHERE Resolved = 0 AND NotifiedAt IS NULL);
    IF @n = 0 RETURN;

    DECLARE @crit INT = (SELECT COUNT(*) FROM mon.AlertHistory WHERE Resolved=0 AND NotifiedAt IS NULL AND Severity='CRIT');
    DECLARE @body NVARCHAR(MAX) =
        N'<div style="font-family:Segoe UI,Arial,sans-serif">'
      + N'<h3 style="margin:0 0 8px">DBADash — ' + CAST(@n AS NVARCHAR(10)) + N' new alert(s)</h3>'
      + N'<table cellpadding="6" cellspacing="0" border="1" style="border-collapse:collapse;font-size:13px">'
      + N'<tr style="background:#f0f0f0"><th>Severity</th><th>Category</th><th>Server</th><th>Detail</th></tr>';

    SELECT @body += CONCAT(
        N'<tr><td style="color:', CASE WHEN Severity='CRIT' THEN '#c00' ELSE '#c80' END, N';font-weight:bold">',
        Severity, N'</td><td>', Category, N'</td><td>', ISNULL(ServerName,N''), N'</td><td>', Message, N'</td></tr>')
    FROM mon.AlertHistory
    WHERE Resolved = 0 AND NotifiedAt IS NULL
    ORDER BY CASE Severity WHEN 'CRIT' THEN 0 ELSE 1 END;

    SET @body += N'</table><p style="color:#888;font-size:12px">DBADash · '
               + CONVERT(VARCHAR(20), SYSUTCDATETIME(), 120) + N' UTC</p></div>';

    DECLARE @subj VARCHAR(200) = CONCAT('[DBADash] ', @n, ' new alert(s)',
                                        CASE WHEN @crit > 0 THEN CONCAT(' (', @crit, ' CRITICAL)') ELSE '' END);

    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = @ProfileName,
        @recipients   = @Recipients,
        @subject      = @subj,
        @body         = @body,
        @body_format  = 'HTML';

    UPDATE mon.AlertHistory SET NotifiedAt = SYSUTCDATETIME()
    WHERE Resolved = 0 AND NotifiedAt IS NULL;
END;
GO

PRINT 'Alerting objects created.';
GO
