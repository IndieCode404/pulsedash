/*==============================================================================
  DBADash  |  15 - Query performance, login audit, Redshift stale data & Spectrum
  ----------------------------------------------------------------------------
  - mon.TopQueries    : heaviest MSSQL statements (dm_exec_query_stats snapshot)
  - mon.FailedLogin   : failed logins, MSSQL (error log) + Redshift (stl_connection_log)
  - mon.LoginActivity : who is connected from where (MSSQL session inventory)
  - mon.TableScan     : per-table last-scan times (Redshift). STL only keeps a few
                        days, but we snapshot every cycle, so the CENTRAL history
                        accumulates - stale detection gets stronger every day.
  - mon.SpectrumScan  : Spectrum usage by external table (~$5/TB scanned)
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

IF OBJECT_ID('mon.TopQueries') IS NULL
CREATE TABLE mon.TopQueries
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME       NOT NULL,
    DatabaseName NVARCHAR(128) NULL,
    QueryText   NVARCHAR(500) NULL,
    ExecCount   BIGINT NULL,
    TotalCpuMs  BIGINT NULL,
    AvgCpuMs    BIGINT NULL,
    AvgDurMs    BIGINT NULL,
    AvgReads    BIGINT NULL,
    LastExec    DATETIME2(0) NULL
);
GO
IF OBJECT_ID('mon.FailedLogin') IS NULL
CREATE TABLE mon.FailedLogin
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    Platform    VARCHAR(20)   NOT NULL,
    ServerName  SYSNAME       NOT NULL,
    EventTime   DATETIME2(0)  NULL,
    Message     NVARCHAR(500) NULL
);
GO
IF OBJECT_ID('mon.LoginActivity') IS NULL
CREATE TABLE mon.LoginActivity
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME       NOT NULL,
    LoginName   NVARCHAR(128) NULL,
    HostName    NVARCHAR(128) NULL,
    ProgramName NVARCHAR(160) NULL,
    SessionCount INT NULL,
    LastLogin   DATETIME2(0) NULL
);
GO
IF OBJECT_ID('mon.TableScan') IS NULL
CREATE TABLE mon.TableScan
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME       NOT NULL,
    TableName   NVARCHAR(256) NOT NULL,
    LastScanned DATETIME2(0)  NULL
);
GO
IF OBJECT_ID('mon.SpectrumScan') IS NULL
CREATE TABLE mon.SpectrumScan
(
    SnapshotID  BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName  SYSNAME       NOT NULL,
    ExternalTable NVARCHAR(256) NOT NULL,
    QueryCount  INT   NULL,
    TBScanned   FLOAT NULL
);
GO

/*------------------------------ views --------------------------------------*/
CREATE OR ALTER VIEW rpt.TopQueries
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.TopQueries
)
SELECT ServerName, DatabaseName, QueryText, ExecCount, TotalCpuMs, AvgCpuMs,
       AvgDurMs, AvgReads, LastExec, CollectedAt
FROM latest WHERE rn = 1;
GO

CREATE OR ALTER VIEW rpt.FailedLogins
AS
SELECT Platform, ServerName, EventTime, Message = MAX(Message), LastSeen = MAX(CollectedAt)
FROM mon.FailedLogin
WHERE EventTime >= DATEADD(DAY, -7, SYSUTCDATETIME())
GROUP BY Platform, ServerName, EventTime, Message;   -- dedup across runs
GO

CREATE OR ALTER VIEW rpt.LoginActivity
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.LoginActivity
)
SELECT ServerName, LoginName, HostName, ProgramName, SessionCount, LastLogin, CollectedAt
FROM latest WHERE rn = 1;
GO

/*---------------------------------------------------------------------------
  rpt.StaleTables  -  Redshift tables consuming storage but not being read.
  LastScanned = the most recent scan we have EVER observed (history accrues
  centrally). MonitoredDays shows how long we've been watching, so "never
  scanned" is only meaningful once MonitoredDays is respectable.
  Cost estimate: RA3 managed storage ~ $0.024/GB-month.
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.StaleTables
AS
WITH sz AS
(
    SELECT ServerName, ObjectName, SizeBytes,
           rn = ROW_NUMBER() OVER (PARTITION BY ServerName, ObjectName ORDER BY CollectedAt DESC),
           firstSeen = MIN(CollectedAt) OVER (PARTITION BY ServerName, ObjectName)
    FROM mon.ObjectSize
    WHERE Platform = 'Redshift' AND ObjectType = 'table'
),
scans AS
(
    SELECT ServerName, TableName, LastScanned = MAX(LastScanned)
    FROM mon.TableScan GROUP BY ServerName, TableName
)
SELECT
    sz.ServerName,
    TableName     = sz.ObjectName,
    SizeGB        = CAST(sz.SizeBytes / 1073741824.0 AS DECIMAL(12,1)),
    LastScanned   = sc.LastScanned,
    DaysSinceScan = DATEDIFF(DAY, sc.LastScanned, SYSUTCDATETIME()),
    MonitoredDays = DATEDIFF(DAY, sz.firstSeen, SYSUTCDATETIME()),
    EstMonthlyUSD = CAST(sz.SizeBytes / 1073741824.0 * 0.024 AS DECIMAL(12,2)),
    Status = CASE
        WHEN sc.LastScanned IS NULL AND DATEDIFF(DAY, sz.firstSeen, SYSUTCDATETIME()) < 7 THEN 'OK'   -- too early to judge
        WHEN sc.LastScanned IS NULL                                   THEN 'CRIT'  -- never seen read
        WHEN DATEDIFF(DAY, sc.LastScanned, SYSUTCDATETIME()) >= 60    THEN 'CRIT'
        WHEN DATEDIFF(DAY, sc.LastScanned, SYSUTCDATETIME()) >= 30    THEN 'WARN'
        ELSE 'OK' END
FROM sz
LEFT JOIN scans sc ON sc.ServerName = sz.ServerName AND sc.TableName = sz.ObjectName
WHERE sz.rn = 1;
GO

/*---------------------------------------------------------------------------
  rpt.SpectrumByTable  -  Spectrum usage per external table (latest 24h window)
  at the published ~$5.00 per TB scanned.
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.SpectrumByTable
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.SpectrumScan
)
SELECT ServerName, ExternalTable, QueryCount,
       TBScanned  = CAST(TBScanned AS DECIMAL(12,4)),
       EstCostUSD = CAST(TBScanned * 5.0 AS DECIMAL(12,2)),
       CollectedAt
FROM latest WHERE rn = 1;
GO

/*-------- purge v3: include the new time-series tables ----------------------*/
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
    -- NOTE: mon.TableScan is intentionally NOT purged by retention: keeping the
    -- full last-scan history is what makes stale-table detection accurate.
    -- It stays tiny (one row per table per day at most matters; dedupe below).
    ;WITH d AS (SELECT *, rn=ROW_NUMBER() OVER (PARTITION BY ServerName, TableName, CAST(LastScanned AS DATE) ORDER BY SnapshotID DESC)
                FROM mon.TableScan)
    DELETE FROM d WHERE rn > 1;
    DELETE FROM cfg.CollectionLog WHERE RunAt < @cut;
END;
GO

PRINT 'Perf / login-audit / stale-data / Spectrum objects created (15).';
GO
