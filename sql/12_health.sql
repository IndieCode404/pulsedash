/*==============================================================================
  DBADash  |  12 - Proactive health: backups, CHECKDB, jobs, activity, waits,
                   instance vitals, Redshift table health
  ----------------------------------------------------------------------------
  The DBA morning-checklist items, collected every cycle so the dashboard (and
  the alert emails) surface them BEFORE users call. This file also supersedes
  cfg.usp_Evaluate_Alerts and rpt.Overview (redefined to include new domains).
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

/*------------------------------ tables -------------------------------------*/
IF OBJECT_ID('mon.BackupStatus') IS NULL
CREATE TABLE mon.BackupStatus
(
    SnapshotID      BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt     DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName      SYSNAME      NOT NULL,
    DatabaseName    SYSNAME      NOT NULL,
    RecoveryModel   VARCHAR(20)  NULL,
    StateDesc       VARCHAR(30)  NULL,        -- ONLINE / RESTORING / SUSPECT ...
    LastFullBackup  DATETIME2(0) NULL,
    LastDiffBackup  DATETIME2(0) NULL,
    LastLogBackup   DATETIME2(0) NULL,
    LastGoodCheckDb DATETIME2(0) NULL         -- DBCC CHECKDB last known good
);
GO
IF OBJECT_ID('mon.JobFailure') IS NULL
CREATE TABLE mon.JobFailure
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME       NOT NULL,
    JobName     SYSNAME       NOT NULL,
    StepName    NVARCHAR(256) NULL,
    RunAt       DATETIME2(0)  NOT NULL,
    Message     NVARCHAR(600) NULL
);
GO
IF OBJECT_ID('mon.HealthMetric') IS NULL      -- key/value instance vitals
CREATE TABLE mon.HealthMetric
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    Platform    VARCHAR(20)  NOT NULL,
    ServerName  SYSNAME      NOT NULL,
    MetricName  VARCHAR(60)  NOT NULL,
    MetricValue FLOAT        NOT NULL,
    Detail      NVARCHAR(256) NULL
);
GO
IF OBJECT_ID('mon.QuerySnapshot') IS NULL     -- blocking + long-running queries
CREATE TABLE mon.QuerySnapshot
(
    SnapshotID   BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    Platform     VARCHAR(20)   NOT NULL,
    ServerName   SYSNAME       NOT NULL,
    SessionID    INT           NOT NULL,
    BlockedBy    INT           NULL,
    Status       VARCHAR(40)   NULL,
    WaitType     NVARCHAR(80)  NULL,
    DurationSec  BIGINT        NULL,
    DatabaseName NVARCHAR(128) NULL,
    LoginName    NVARCHAR(128) NULL,
    HostName     NVARCHAR(128) NULL,
    ProgramName  NVARCHAR(160) NULL,
    QueryText    NVARCHAR(500) NULL
);
GO
IF OBJECT_ID('mon.WaitStats') IS NULL
CREATE TABLE mon.WaitStats
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME      NOT NULL,
    WaitType    NVARCHAR(80) NOT NULL,
    WaitTimeMs  BIGINT       NOT NULL,
    WaitPct     DECIMAL(5,1) NULL
);
GO
IF OBJECT_ID('mon.TableHealth') IS NULL       -- Redshift vacuum/analyze debt
CREATE TABLE mon.TableHealth
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME       NOT NULL,
    TableName   NVARCHAR(256) NOT NULL,
    UnsortedPct DECIMAL(5,1)  NULL,
    StatsOffPct DECIMAL(5,1)  NULL,
    TableRows   BIGINT        NULL
);
GO

/*------------------------------ views --------------------------------------*/
CREATE OR ALTER VIEW rpt.BackupHealth
AS
WITH latest AS
(
    SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, DatabaseName ORDER BY CollectedAt DESC)
    FROM mon.BackupStatus
)
SELECT ServerName, DatabaseName, RecoveryModel, StateDesc,
       LastFullBackup, LastDiffBackup, LastLogBackup,
       LastGoodCheckDb = NULLIF(LastGoodCheckDb, '19000101'),
       HoursSinceFull  = DATEDIFF(HOUR, LastFullBackup, SYSUTCDATETIME()),
       MinsSinceLog    = CASE WHEN RecoveryModel IN ('FULL','BULK_LOGGED')
                              THEN DATEDIFF(MINUTE, LastLogBackup, SYSUTCDATETIME()) END,
       CollectedAt,
       Status = CASE
           WHEN StateDesc <> 'ONLINE' THEN 'CRIT'
           WHEN LastFullBackup IS NULL
             OR LastFullBackup < DATEADD(DAY, -7, SYSUTCDATETIME()) THEN 'CRIT'
           WHEN RecoveryModel IN ('FULL','BULK_LOGGED')
             AND DatabaseName NOT IN ('master','model','msdb')
             AND (LastLogBackup IS NULL OR LastLogBackup < DATEADD(HOUR, -6, SYSUTCDATETIME())) THEN 'CRIT'
           WHEN LastFullBackup < DATEADD(DAY, -2, SYSUTCDATETIME()) THEN 'WARN'
           WHEN RecoveryModel IN ('FULL','BULK_LOGGED')
             AND DatabaseName NOT IN ('master','model','msdb')
             AND LastLogBackup < DATEADD(HOUR, -1, SYSUTCDATETIME()) THEN 'WARN'
           WHEN NULLIF(LastGoodCheckDb,'19000101') IS NULL
             OR LastGoodCheckDb < DATEADD(DAY, -30, SYSUTCDATETIME()) THEN 'WARN'
           ELSE 'OK' END
FROM latest WHERE rn = 1;
GO

CREATE OR ALTER VIEW rpt.JobFailures
AS
SELECT ServerName, JobName, StepName, RunAt,
       Message = MAX(Message), LastSeen = MAX(CollectedAt)
FROM mon.JobFailure
WHERE RunAt >= DATEADD(DAY, -7, SYSUTCDATETIME())
GROUP BY ServerName, JobName, StepName, RunAt;   -- dedup across collection runs
GO

CREATE OR ALTER VIEW rpt.InstanceVitals
AS
WITH latest AS
(
    SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY Platform, ServerName, MetricName ORDER BY CollectedAt DESC)
    FROM mon.HealthMetric
)
SELECT Platform, ServerName, MetricName, MetricValue, Detail, CollectedAt,
       Status = CASE
           WHEN MetricName = 'page_life_expectancy'  AND MetricValue < 100 THEN 'CRIT'
           WHEN MetricName = 'page_life_expectancy'  AND MetricValue < 300 THEN 'WARN'
           WHEN MetricName = 'memory_grants_pending' AND MetricValue >= 5  THEN 'CRIT'
           WHEN MetricName = 'memory_grants_pending' AND MetricValue > 0   THEN 'WARN'
           WHEN MetricName = 'blocked_sessions'      AND MetricValue >= 5  THEN 'CRIT'
           WHEN MetricName = 'blocked_sessions'      AND MetricValue > 0   THEN 'WARN'
           WHEN MetricName = 'queued_queries'        AND MetricValue > 0   THEN 'WARN'
           WHEN MetricName = 'load_errors_24h'       AND MetricValue > 0   THEN 'WARN'
           ELSE 'OK' END
FROM latest WHERE rn = 1;
GO

CREATE OR ALTER VIEW rpt.ActiveQueries
AS
WITH latest AS   -- most recent snapshot per server
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY Platform, ServerName ORDER BY CollectedAt DESC)
    FROM mon.QuerySnapshot
)
SELECT Platform, ServerName, SessionID, BlockedBy, Status, WaitType, DurationSec,
       DatabaseName, LoginName, HostName, ProgramName, QueryText, CollectedAt,
       RowStatus = CASE WHEN ISNULL(BlockedBy,0) <> 0 THEN 'CRIT'
                        WHEN DurationSec >= 600 THEN 'WARN' ELSE 'OK' END
FROM latest WHERE rn = 1;
GO

CREATE OR ALTER VIEW rpt.TopWaits
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.WaitStats
)
SELECT ServerName, WaitType, WaitTimeMs, WaitPct, CollectedAt
FROM latest WHERE rn = 1;
GO

CREATE OR ALTER VIEW rpt.TableHealth
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.TableHealth
)
SELECT ServerName, TableName, UnsortedPct, StatsOffPct, TableRows, CollectedAt,
       Status = CASE WHEN UnsortedPct >= 50 OR StatsOffPct >= 50 THEN 'CRIT'
                     WHEN UnsortedPct >= 20 OR StatsOffPct >= 20 THEN 'WARN'
                     ELSE 'OK' END
FROM latest WHERE rn = 1;
GO

/*------------------- rpt.Overview v2 (adds health KPIs) --------------------*/
CREATE OR ALTER VIEW rpt.Overview
AS
SELECT
    Servers            = (SELECT COUNT(*) FROM cfg.Servers WHERE IsActive = 1),
    MSSQLServers       = (SELECT COUNT(*) FROM cfg.Servers WHERE IsActive = 1 AND Platform = 'MSSQL'),
    RedshiftClusters   = (SELECT COUNT(*) FROM cfg.Servers WHERE IsActive = 1 AND Platform = 'Redshift'),
    AGDatabases        = (SELECT COUNT(*) FROM rpt.AGSyncStatus),
    AGUnhealthy        = (SELECT COUNT(*) FROM rpt.AGSyncStatus WHERE Status <> 'OK'),
    LagObjectsCrit     = (SELECT COUNT(*) FROM rpt.DataLag      WHERE Status = 'CRIT'),
    DisksCrit          = (SELECT COUNT(*) FROM rpt.DiskForecast WHERE Severity = 'CRIT'),
    DisksWarn          = (SELECT COUNT(*) FROM rpt.DiskForecast WHERE Severity = 'WARN'),
    BackupsAtRisk      = (SELECT COUNT(*) FROM rpt.BackupHealth WHERE Status <> 'OK'),
    JobFailures24h     = (SELECT COUNT(*) FROM rpt.JobFailures  WHERE RunAt >= DATEADD(HOUR,-24,SYSUTCDATETIME())),
    BlockedSessions    = (SELECT ISNULL(SUM(MetricValue),0) FROM rpt.InstanceVitals WHERE MetricName='blocked_sessions'),
    AppsWithoutOwner   = (SELECT COUNT(*) FROM cfg.Servers s
                          WHERE s.IsActive = 1
                            AND NOT EXISTS (SELECT 1 FROM cfg.AppOwners a WHERE a.ServerName = s.ServerName)),
    LastCollection     = (SELECT MAX(RunAt) FROM cfg.CollectionLog WHERE Status = 'OK');
GO

/*------------- cfg.usp_Evaluate_Alerts v2 (supersedes sql\10) --------------
  Same dedup/auto-resolve mechanics; now also raises Backup / Job / Blocking /
  TableHealth alerts so the email covers the whole morning checklist.        */
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

    INSERT #cur
    SELECT CONCAT('Backup|',ServerName,'|',DatabaseName), 'Backup', Status, ServerName,
           CONCAT(DatabaseName,' [',StateDesc,'/',RecoveryModel,'] last full ',
                  ISNULL(CONVERT(VARCHAR(16),LastFullBackup,120),'NEVER'),
                  ', last log ', ISNULL(CONVERT(VARCHAR(16),LastLogBackup,120),'n/a'),
                  ', last CHECKDB ', ISNULL(CONVERT(VARCHAR(10),LastGoodCheckDb,120),'NEVER'))
    FROM rpt.BackupHealth WHERE Status IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('Job|',ServerName,'|',JobName,'|',CONVERT(VARCHAR(16),RunAt,120)), 'Job', 'WARN', ServerName,
           CONCAT('Agent job failed: ',JobName,' (',ISNULL(StepName,'?'),') at ',CONVERT(VARCHAR(16),RunAt,120))
    FROM rpt.JobFailures WHERE RunAt >= DATEADD(HOUR, -24, SYSUTCDATETIME());

    INSERT #cur
    SELECT CONCAT('Vitals|',ServerName,'|',MetricName), 'Vitals', Status, ServerName,
           CONCAT(ServerName,' ',MetricName,' = ',CAST(MetricValue AS VARCHAR(20)))
    FROM rpt.InstanceVitals WHERE Status IN ('WARN','CRIT');

    INSERT #cur
    SELECT CONCAT('TableHealth|',ServerName,'|',TableName), 'TableHealth', Status, ServerName,
           CONCAT(TableName,' unsorted=',UnsortedPct,'% stats_off=',StatsOffPct,'% - run VACUUM/ANALYZE')
    FROM rpt.TableHealth WHERE Status = 'CRIT';   -- WARN-level debt stays on the dashboard only

    MERGE mon.AlertHistory AS t
    USING #cur AS s ON t.AlertKey = s.AlertKey AND t.Resolved = 0
    WHEN MATCHED THEN UPDATE SET
        t.Severity = s.Severity, t.Message = s.Message, t.LastSeen = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
        (AlertKey, Category, Severity, ServerName, Message)
        VALUES (s.AlertKey, s.Category, s.Severity, s.ServerName, s.Message);

    UPDATE t SET Resolved = 1, ResolvedAt = SYSUTCDATETIME()
    FROM mon.AlertHistory t
    WHERE t.Resolved = 0
      AND NOT EXISTS (SELECT 1 FROM #cur c WHERE c.AlertKey = t.AlertKey);

    SELECT ActiveAlerts = (SELECT COUNT(*) FROM mon.AlertHistory WHERE Resolved = 0);
END;
GO

/*-------- extend the purge proc to cover the new time-series tables --------*/
CREATE OR ALTER PROCEDURE cfg.usp_Purge_History
    @RetentionDays INT = 90
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @cut DATETIME2(0) = DATEADD(DAY, -@RetentionDays, SYSUTCDATETIME());
    DELETE FROM mon.AGSyncStatus  WHERE CollectedAt < @cut;
    DELETE FROM mon.DataLag       WHERE CollectedAt < @cut;
    DELETE FROM mon.DiskUsage     WHERE CollectedAt < @cut;
    DELETE FROM mon.ObjectSize    WHERE CollectedAt < @cut;
    DELETE FROM mon.RedshiftCost  WHERE CollectedAt < @cut;
    DELETE FROM mon.BackupStatus  WHERE CollectedAt < @cut;
    DELETE FROM mon.JobFailure    WHERE CollectedAt < @cut;
    DELETE FROM mon.HealthMetric  WHERE CollectedAt < @cut;
    DELETE FROM mon.QuerySnapshot WHERE CollectedAt < @cut;
    DELETE FROM mon.WaitStats     WHERE CollectedAt < @cut;
    DELETE FROM mon.TableHealth   WHERE CollectedAt < @cut;
    DELETE FROM cfg.CollectionLog WHERE RunAt       < @cut;
END;
GO

PRINT 'Proactive health objects created (12_health).';
GO
