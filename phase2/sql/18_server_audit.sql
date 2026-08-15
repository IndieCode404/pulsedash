/*==============================================================================
  DBADash  |  18 - Server audit: patch level, config drift, access control,
                   index health  (+ tempdb / VLF vitals)
  ----------------------------------------------------------------------------
  Closes the "sp_Blitz on day one" gaps a DBA expects:
    - mon.ServerInfo        : SQL build / patch level (SP + CU), edition, OS
    - mon.ConfigAudit       : configuration drift (MAXDOP, memory, sa, ...)
    - mon.SecurityPrincipal : logins/roles for ACCESS-CONTROL auditing
    - mon.IndexHealth        : missing / unused / fragmented indexes
  Also extends rpt.InstanceVitals with tempdb + VLF metrics, rpt.Overview with
  new KPIs, and the purge proc with the new tables.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

/*------------------------------ tables -------------------------------------*/
IF OBJECT_ID('mon.ServerInfo') IS NULL
CREATE TABLE mon.ServerInfo
(
    SnapshotID       BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt      DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName       SYSNAME      NOT NULL,
    ProductVersion   NVARCHAR(50) NULL,     -- e.g. 15.0.4360.2
    ProductLevel     NVARCHAR(20) NULL,     -- RTM / SP1 ...
    ProductUpdateLevel NVARCHAR(20) NULL,   -- CU level, e.g. CU18
    Edition          NVARCHAR(80) NULL,
    ProductMajor     NVARCHAR(40) NULL,     -- major version number
    HostPlatform     NVARCHAR(40) NULL,     -- Windows / Linux
    OSVersion        NVARCHAR(120) NULL,
    IsClustered      BIT NULL,
    IsHadrEnabled    BIT NULL,
    StartTime        DATETIME2(0) NULL,
    CpuCount         INT NULL,
    PhysicalMemoryMB BIGINT NULL
);
GO
IF OBJECT_ID('mon.ConfigAudit') IS NULL
CREATE TABLE mon.ConfigAudit
(
    SnapshotID   BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName   SYSNAME       NOT NULL,
    ConfigItem   NVARCHAR(80)  NOT NULL,
    CurrentValue NVARCHAR(100) NULL,
    RecommendedValue NVARCHAR(100) NULL,
    Status       VARCHAR(10)   NOT NULL,    -- OK | WARN | CRIT
    Detail       NVARCHAR(400) NULL
);
GO
IF OBJECT_ID('mon.SecurityPrincipal') IS NULL
CREATE TABLE mon.SecurityPrincipal
(
    SnapshotID    BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt   DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName    SYSNAME       NOT NULL,
    PrincipalName NVARCHAR(256) NOT NULL,
    PrincipalType NVARCHAR(40)  NULL,       -- SQL_LOGIN / WINDOWS_LOGIN / WINDOWS_GROUP
    AccessType    VARCHAR(30)   NULL,       -- Sysadmin / Security admin / Elevated / Standard / Connect-only / Disabled
    ServerRoles   NVARCHAR(400) NULL,       -- csv of fixed server roles
    IsDisabled    BIT           NULL,
    CreateDate    DATETIME2(0)  NULL,
    LastModified  DATETIME2(0)  NULL
);
GO
IF OBJECT_ID('mon.IndexHealth') IS NULL
CREATE TABLE mon.IndexHealth
(
    SnapshotID   BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName   SYSNAME       NOT NULL,
    DatabaseName NVARCHAR(128) NULL,
    Kind         VARCHAR(20)   NOT NULL,    -- missing | unused | fragmented
    ObjectName   NVARCHAR(300) NULL,
    IndexName    NVARCHAR(256) NULL,
    Metric       NVARCHAR(120) NULL,        -- impact / reads-writes / frag%
    Recommendation NVARCHAR(600) NULL
);
GO

/*------------------------------ views --------------------------------------*/
CREATE OR ALTER VIEW rpt.ServerInfo
AS
WITH latest AS
(
    SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.ServerInfo
)
SELECT ServerName, ProductMajor, ProductVersion, ProductLevel, ProductUpdateLevel,
       Edition, HostPlatform, OSVersion, IsClustered, IsHadrEnabled,
       StartTime, CpuCount, PhysicalMemoryMB, CollectedAt,
       -- friendly "patch" line, e.g.  SQL 2019 · 15.0.4360.2 · RTM-CU18
       PatchLevel = CONCAT('v', ProductVersion,
                           CASE WHEN ProductLevel IS NOT NULL THEN ' · ' + ProductLevel ELSE '' END,
                           CASE WHEN NULLIF(ProductUpdateLevel,'') IS NOT NULL THEN '-' + ProductUpdateLevel ELSE '' END)
FROM latest WHERE rn = 1;
GO

CREATE OR ALTER VIEW rpt.ConfigAudit
AS
WITH latest AS
(
    SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, ConfigItem ORDER BY CollectedAt DESC)
    FROM mon.ConfigAudit
)
SELECT ServerName, ConfigItem, CurrentValue, RecommendedValue, Status, Detail, CollectedAt
FROM latest WHERE rn = 1;
GO

CREATE OR ALTER VIEW rpt.Principals
AS
WITH latest AS
(
    SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY ServerName, PrincipalName ORDER BY CollectedAt DESC)
    FROM mon.SecurityPrincipal
)
SELECT ServerName, PrincipalName, PrincipalType, AccessType, ServerRoles,
       IsDisabled, CreateDate, LastModified, CollectedAt
FROM latest WHERE rn = 1;
GO

-- Access-control rollup: how many principals hold each type of access, per server.
CREATE OR ALTER VIEW rpt.AccessControl
AS
SELECT ServerName, AccessType,
       Principals = COUNT(*),
       Status = CASE
           WHEN AccessType = 'Sysadmin'      AND COUNT(*) > 5 THEN 'WARN'
           WHEN AccessType = 'Security admin' AND COUNT(*) > 3 THEN 'WARN'
           ELSE 'OK' END
FROM rpt.Principals
GROUP BY ServerName, AccessType;
GO

CREATE OR ALTER VIEW rpt.IndexHealth
AS
WITH latest AS
(
    SELECT *, rn = DENSE_RANK() OVER (PARTITION BY ServerName ORDER BY CollectedAt DESC)
    FROM mon.IndexHealth
)
SELECT ServerName, DatabaseName, Kind, ObjectName, IndexName, Metric, Recommendation, CollectedAt,
       Status = CASE Kind WHEN 'missing' THEN 'WARN' WHEN 'fragmented' THEN 'WARN' ELSE 'OK' END
FROM latest WHERE rn = 1;
GO

/*------------- rpt.InstanceVitals v2: add tempdb + VLF thresholds ----------*/
CREATE OR ALTER VIEW rpt.InstanceVitals
AS
WITH latest AS
(
    SELECT *, rn = ROW_NUMBER() OVER (PARTITION BY Platform, ServerName, MetricName ORDER BY CollectedAt DESC)
    FROM mon.HealthMetric
)
SELECT Platform, ServerName, MetricName, MetricValue, Detail, CollectedAt,
       Status = CASE
           WHEN MetricName = 'page_life_expectancy'    AND MetricValue < 100 THEN 'CRIT'
           WHEN MetricName = 'page_life_expectancy'    AND MetricValue < 300 THEN 'WARN'
           WHEN MetricName = 'memory_grants_pending'   AND MetricValue >= 5  THEN 'CRIT'
           WHEN MetricName = 'memory_grants_pending'   AND MetricValue > 0   THEN 'WARN'
           WHEN MetricName = 'blocked_sessions'        AND MetricValue >= 5  THEN 'CRIT'
           WHEN MetricName = 'blocked_sessions'        AND MetricValue > 0   THEN 'WARN'
           WHEN MetricName = 'queued_queries'          AND MetricValue > 0   THEN 'WARN'
           WHEN MetricName = 'load_errors_24h'         AND MetricValue > 0   THEN 'WARN'
           WHEN MetricName = 'suspect_pages'           AND MetricValue > 0   THEN 'CRIT'
           WHEN MetricName = 'cpu_pct'                 AND MetricValue >= 95 THEN 'CRIT'
           WHEN MetricName = 'cpu_pct'                 AND MetricValue >= 80 THEN 'WARN'
           WHEN MetricName = 'tempdb_version_store_gb' AND MetricValue >= 150 THEN 'CRIT'
           WHEN MetricName = 'tempdb_version_store_gb' AND MetricValue >= 50  THEN 'WARN'
           WHEN MetricName = 'max_vlf_count'           AND MetricValue >= 10000 THEN 'CRIT'
           WHEN MetricName = 'max_vlf_count'           AND MetricValue >= 1000  THEN 'WARN'
           ELSE 'OK' END
FROM latest WHERE rn = 1;
GO

/*------------- rpt.Overview v4: add config + sysadmin KPIs -----------------*/
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
    AppsWithoutOwner   = (SELECT COUNT(*) FROM cfg.Servers s
                          WHERE s.IsActive = 1
                            AND NOT EXISTS (SELECT 1 FROM cfg.AppOwners a WHERE a.ServerName = s.ServerName)),
    LastCollection     = (SELECT MAX(RunAt) FROM cfg.CollectionLog WHERE Status = 'OK');
GO

/*-------- purge v5 (supersedes sql\17): also cover the audit tables ---------*/
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
    ;WITH d AS (SELECT *, rn=ROW_NUMBER() OVER (PARTITION BY ServerName, TableName, CAST(LastScanned AS DATE) ORDER BY SnapshotID DESC)
                FROM mon.TableScan)
    DELETE FROM d WHERE rn > 1;
    DELETE FROM cfg.CollectionLog WHERE RunAt < @cut;
END;
GO

PRINT 'Server-audit objects created (18): patch, config drift, access control, index health.';
GO
