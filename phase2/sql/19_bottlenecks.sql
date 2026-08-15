/*==============================================================================
  DBADash  |  19 - Performance bottlenecks: file I/O latency, wait deltas,
                   autogrowth events
  ----------------------------------------------------------------------------
  The "what is slow right now" trio a DBA reaches for when chasing bottlenecks:
    - mon.FileIOStats      : per-file read/write latency (dm_io_virtual_file_stats)
    - rpt.WaitDelta        : waits accrued between the last TWO snapshots - shows
                             CHANGE, not cumulative-since-restart (view only)
    - mon.AutoGrowth       : file auto-grow events (default trace) - I/O freezes
  Feeds a new "Bottlenecks" dashboard tab + an I/O-hotspots KPI. Also bumps
  rpt.Overview (v5) and cfg.usp_Purge_History (v6).
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

/*------------------------------ tables -------------------------------------*/
IF OBJECT_ID('mon.FileIOStats') IS NULL
CREATE TABLE mon.FileIOStats
(
    SnapshotID   BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName   SYSNAME       NOT NULL,
    DatabaseName NVARCHAR(128) NULL,
    FileType     VARCHAR(20)   NULL,     -- ROWS / LOG
    ReadLatencyMs  DECIMAL(10,1) NULL,   -- io_stall_read_ms / num_of_reads
    WriteLatencyMs DECIMAL(10,1) NULL,
    AvgLatencyMs   DECIMAL(10,1) NULL,
    SizeMB       BIGINT NULL,
    TotalReadMB  BIGINT NULL,
    TotalWriteMB BIGINT NULL
);
GO
IF OBJECT_ID('mon.AutoGrowth') IS NULL
CREATE TABLE mon.AutoGrowth
(
    SnapshotID   BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName   SYSNAME       NOT NULL,
    EventTime    DATETIME2(0)  NULL,
    DatabaseName NVARCHAR(128) NULL,
    FileType     VARCHAR(20)   NULL,     -- ROWS / LOG
    GrowthMB     DECIMAL(10,1) NULL,
    DurationMs   BIGINT        NULL      -- how long the grow stalled I/O
);
GO

/*------------------------------ views --------------------------------------*/
-- Per-file latency, latest snapshot. Guidance: <10ms good, 20-50 concerning, >50 bad.
CREATE OR ALTER VIEW rpt.FileIOStats
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.FileIOStats
)
SELECT ServerName, DatabaseName, FileType, ReadLatencyMs, WriteLatencyMs, AvgLatencyMs,
       SizeMB, TotalReadMB, TotalWriteMB, CollectedAt,
       Status = CASE WHEN ReadLatencyMs >= 50 OR WriteLatencyMs >= 50 THEN 'CRIT'
                     WHEN ReadLatencyMs >= 20 OR WriteLatencyMs >= 20 THEN 'WARN'
                     ELSE 'OK' END
FROM latest WHERE rn = 1;
GO

-- Wait time accrued BETWEEN the two most recent snapshots (~one collection cycle).
-- This is the "what changed" signal; mon.WaitStats itself is cumulative-since-restart.
CREATE OR ALTER VIEW rpt.WaitDelta
AS
WITH ranked AS
(
    SELECT ServerName, WaitType, WaitTimeMs, CollectedAt,
           rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.WaitStats
),
d AS
(
    SELECT c.ServerName, c.WaitType, c.CollectedAt,
           DeltaMs = CASE WHEN p.WaitTimeMs IS NULL OR c.WaitTimeMs < p.WaitTimeMs
                          THEN c.WaitTimeMs                 -- restart or newly-seen wait
                          ELSE c.WaitTimeMs - p.WaitTimeMs END
    FROM        (SELECT * FROM ranked WHERE rn = 1) c
    LEFT JOIN   (SELECT * FROM ranked WHERE rn = 2) p
           ON p.ServerName = c.ServerName AND p.WaitType = c.WaitType
)
SELECT ServerName, WaitType, DeltaMs, CollectedAt,
       WaitPct = CAST(100.0 * DeltaMs / NULLIF(SUM(DeltaMs) OVER (PARTITION BY ServerName), 0) AS DECIMAL(5,1))
FROM d WHERE DeltaMs > 0;
GO

-- Recent autogrowth events (default trace), deduped across collection runs.
CREATE OR ALTER VIEW rpt.AutoGrowthEvents
AS
WITH dedup AS
(
    SELECT ServerName, EventTime, DatabaseName, FileType,
           GrowthMB = MAX(GrowthMB), DurationMs = MAX(DurationMs)
    FROM mon.AutoGrowth
    WHERE EventTime >= DATEADD(DAY, -7, SYSUTCDATETIME())
    GROUP BY ServerName, EventTime, DatabaseName, FileType
)
SELECT ServerName, EventTime, DatabaseName, FileType, GrowthMB, DurationMs,
       Status = CASE WHEN DurationMs >= 1000 THEN 'WARN' ELSE 'OK' END   -- >1s grow = I/O stall
FROM dedup;
GO

/*------------- rpt.Overview v5: add the I/O-hotspots KPI -------------------*/
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
    OpenFindings       = (SELECT COUNT(*) FROM mon.Finding WHERE Resolved = 0),
    ConfigWarnings     = (SELECT COUNT(*) FROM rpt.ConfigAudit WHERE Status IN ('WARN','CRIT')),
    Sysadmins          = (SELECT ISNULL(SUM(Principals),0) FROM rpt.AccessControl WHERE AccessType = 'Sysadmin'),
    HighLatencyFiles   = (SELECT COUNT(*) FROM rpt.FileIOStats WHERE Status IN ('WARN','CRIT')),
    AppsWithoutOwner   = (SELECT COUNT(*) FROM cfg.Servers s
                          WHERE s.IsActive = 1
                            AND NOT EXISTS (SELECT 1 FROM cfg.AppOwners a WHERE a.ServerName = s.ServerName)),
    LastCollection     = (SELECT MAX(RunAt) FROM cfg.CollectionLog WHERE Status = 'OK');
GO

/*-------- purge v6 (supersedes sql\18): + FileIOStats, AutoGrowth ----------*/
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
    -- keep mon.TableScan history (stale-table detection); dedupe to daily instead
    ;WITH d AS (SELECT *, rn=ROW_NUMBER() OVER (PARTITION BY ServerName, TableName, CAST(LastScanned AS DATE) ORDER BY SnapshotID DESC)
                FROM mon.TableScan)
    DELETE FROM d WHERE rn > 1;
    -- collapse autogrowth dupes (re-read from the default trace every cycle)
    ;WITH ag AS (SELECT *, rn=ROW_NUMBER() OVER (PARTITION BY ServerName, EventTime, DatabaseName, FileType ORDER BY SnapshotID DESC)
                 FROM mon.AutoGrowth)
    DELETE FROM ag WHERE rn > 1;
    DELETE FROM cfg.CollectionLog WHERE RunAt < @cut;
END;
GO

PRINT 'Bottleneck objects created (19): file I/O latency, wait deltas, autogrowth.';
GO
