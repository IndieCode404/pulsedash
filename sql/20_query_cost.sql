/*==============================================================================
  DBADash  |  20 - Redshift cost attribution BY QUERY
  ----------------------------------------------------------------------------
  "Which queries are running up the AWS bill?" - the per-query companion to the
  cost-anomaly (metric-level) and Spectrum-by-table views.
    - mon.QueryCost   : top queries in the last 24h by Spectrum $ + bytes scanned
    - rpt.CostlyQueries: est $/query (Spectrum @ $5/TB) + scan volume + who ran it
  Shows on the Cost tab. Bumps cfg.usp_Purge_History (v7).
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('mon.QueryCost') IS NULL
CREATE TABLE mon.QueryCost
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME       NOT NULL,
    QueryId     BIGINT        NULL,
    UserName    NVARCHAR(128) NULL,
    StartTime   DATETIME2(0)  NULL,
    ElapsedSec  INT           NULL,
    ScanMB      DECIMAL(18,1) NULL,     -- local bytes scanned (compute pressure)
    SpectrumMB  DECIMAL(18,1) NULL,     -- S3 bytes scanned (directly billed)
    EstCostUSD  DECIMAL(12,2) NULL,     -- Spectrum @ $5/TB
    QueryText   NVARCHAR(500) NULL
);
GO

CREATE OR ALTER VIEW rpt.CostlyQueries
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.QueryCost
)
SELECT ServerName, QueryId, UserName, StartTime, ElapsedSec,
       ScanGB     = CAST(ScanMB / 1024.0 AS DECIMAL(14,1)),
       SpectrumGB = CAST(SpectrumMB / 1024.0 AS DECIMAL(14,1)),
       EstCostUSD, QueryText, CollectedAt,
       Status = CASE WHEN EstCostUSD >= 10 THEN 'CRIT'
                     WHEN EstCostUSD >= 1 OR ScanMB >= 512000 THEN 'WARN'  -- >=$1 Spectrum or >=500 GB scanned
                     ELSE 'OK' END
FROM latest WHERE rn = 1;
GO

/*-------- purge v7 (supersedes sql\19): + mon.QueryCost --------------------*/
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
    DELETE FROM mon.TopQueries    WHERE CollectedAt < @cut;
    DELETE FROM mon.FailedLogin   WHERE CollectedAt < @cut;
    DELETE FROM mon.LoginActivity WHERE CollectedAt < @cut;
    DELETE FROM mon.SpectrumScan  WHERE CollectedAt < @cut;
    DELETE FROM mon.LockWait      WHERE CollectedAt < @cut;
    DELETE FROM mon.Finding       WHERE Resolved = 1 AND ResolvedAt < @cut;
    DELETE FROM mon.ServerInfo    WHERE CollectedAt < @cut;
    DELETE FROM mon.ConfigAudit   WHERE CollectedAt < @cut;
    DELETE FROM mon.SecurityPrincipal WHERE CollectedAt < @cut;
    DELETE FROM mon.IndexHealth   WHERE CollectedAt < @cut;
    DELETE FROM mon.FileIOStats   WHERE CollectedAt < @cut;
    DELETE FROM mon.AutoGrowth    WHERE CollectedAt < @cut;
    DELETE FROM mon.QueryCost     WHERE CollectedAt < @cut;
    ;WITH d AS (SELECT *, rn=ROW_NUMBER() OVER (PARTITION BY ServerName, TableName, CAST(LastScanned AS DATE) ORDER BY SnapshotID DESC)
                FROM mon.TableScan)
    DELETE FROM d WHERE rn > 1;
    ;WITH ag AS (SELECT *, rn=ROW_NUMBER() OVER (PARTITION BY ServerName, EventTime, DatabaseName, FileType ORDER BY SnapshotID DESC)
                 FROM mon.AutoGrowth)
    DELETE FROM ag WHERE rn > 1;
    -- Event tables re-read the same 24h window every cycle, so the SAME failed
    -- login / job failure is stored once per run (~96x/day). Collapse to one row
    -- per real event. (The rpt.* views already dedupe for display; this stops the
    -- underlying tables bloating.)
    ;WITH fl AS (SELECT *, rn=ROW_NUMBER() OVER (PARTITION BY ServerName, EventTime, Message ORDER BY SnapshotID DESC)
                 FROM mon.FailedLogin)
    DELETE FROM fl WHERE rn > 1;
    ;WITH jf AS (SELECT *, rn=ROW_NUMBER() OVER (PARTITION BY ServerName, JobName, StepName, RunAt ORDER BY SnapshotID DESC)
                 FROM mon.JobFailure)
    DELETE FROM jf WHERE rn > 1;
    DELETE FROM cfg.CollectionLog WHERE RunAt < @cut;
END;
GO

PRINT 'Redshift query-cost objects created (20).';
GO
