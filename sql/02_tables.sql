/*==============================================================================
  DBADash  |  02 - Tables (inventory + time-series snapshots)
  ----------------------------------------------------------------------------
  All monitoring tables are append-only snapshots (a row per collection run)
  so you get history "for free" and disk forecasting has a trend to fit.
  A nightly purge proc (see 04) trims anything older than @RetentionDays.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

/*---------------------------------------------------------------------------
  cfg.Servers  -  master inventory of everything we monitor (MSSQL + Redshift)
---------------------------------------------------------------------------*/
IF OBJECT_ID('cfg.Servers') IS NULL
CREATE TABLE cfg.Servers
(
    ServerID        INT IDENTITY(1,1) PRIMARY KEY,
    ServerName      SYSNAME       NOT NULL,          -- MSSQL instance or Redshift cluster id
    Platform        VARCHAR(20)   NOT NULL           -- 'MSSQL' | 'Redshift'
        CONSTRAINT CK_Servers_Platform CHECK (Platform IN ('MSSQL','Redshift')),
    Environment     VARCHAR(20)   NOT NULL DEFAULT 'PROD',   -- PROD/UAT/DEV
    FriendlyName    NVARCHAR(128) NULL,
    IsActive        BIT           NOT NULL DEFAULT 1,
    CreatedAt       DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Servers_Name UNIQUE (ServerName)
);
GO

/*---------------------------------------------------------------------------
  mon.AGSyncStatus  -  Always On availability-group replica health snapshots
  One row per (AG, database, replica) per collection run.
---------------------------------------------------------------------------*/
IF OBJECT_ID('mon.AGSyncStatus') IS NULL
CREATE TABLE mon.AGSyncStatus
(
    SnapshotID          BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt         DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    ServerName          SYSNAME      NOT NULL,   -- instance the collector ran on
    AGName              SYSNAME      NOT NULL,
    DatabaseName        SYSNAME      NOT NULL,
    ReplicaServer       SYSNAME      NOT NULL,
    IsPrimary           BIT          NOT NULL,
    Role                VARCHAR(20)  NULL,        -- PRIMARY / SECONDARY
    SyncState           VARCHAR(30)  NULL,        -- SYNCHRONIZED / SYNCHRONIZING / NOT SYNCHRONIZING
    SyncHealth          VARCHAR(30)  NULL,        -- HEALTHY / PARTIALLY_HEALTHY / NOT_HEALTHY
    LogSendQueueKB      BIGINT       NULL,        -- data not yet sent to secondary
    RedoQueueKB         BIGINT       NULL,        -- data received but not yet applied
    LastCommitTime      DATETIME2(0) NULL,        -- used to compute cross-replica lag
    LastHardenedTime    DATETIME2(0) NULL,
    LastRedoneTime      DATETIME2(0) NULL
);
GO
CREATE INDEX IX_AGSync_Latest ON mon.AGSyncStatus (CollectedAt DESC, AGName, DatabaseName);
GO

/*---------------------------------------------------------------------------
  mon.DataLag  -  UNIFIED lag table for both platforms
    MSSQL    : AG secondary redo lag (seconds behind primary)
    Redshift : ETL / load freshness (seconds since last load into a table)
---------------------------------------------------------------------------*/
IF OBJECT_ID('mon.DataLag') IS NULL
CREATE TABLE mon.DataLag
(
    SnapshotID      BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt     DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    Platform        VARCHAR(20)   NOT NULL,      -- MSSQL | Redshift
    ServerName      SYSNAME       NOT NULL,      -- instance / cluster
    ObjectName      NVARCHAR(256) NOT NULL,      -- 'AG:db@secondary' or 'schema.table'
    LagSeconds      BIGINT        NULL,
    Metric          VARCHAR(40)   NOT NULL,      -- 'ag_redo_lag' | 'load_freshness'
    Detail          NVARCHAR(256) NULL
);
GO
CREATE INDEX IX_DataLag_Latest ON mon.DataLag (CollectedAt DESC, Platform, ServerName);
GO

/*---------------------------------------------------------------------------
  mon.DiskUsage  -  UNIFIED disk/volume capacity snapshots
    MSSQL    : one row per OS volume  (sys.dm_os_volume_stats)
    Redshift : one row per node/cluster (stv_partitions rolled up)
  This history is what the forecast proc fits a trend line to.
---------------------------------------------------------------------------*/
IF OBJECT_ID('mon.DiskUsage') IS NULL
CREATE TABLE mon.DiskUsage
(
    SnapshotID      BIGINT IDENTITY(1,1) PRIMARY KEY,
    CollectedAt     DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    Platform        VARCHAR(20)   NOT NULL,      -- MSSQL | Redshift
    ServerName      SYSNAME       NOT NULL,
    VolumeName      NVARCHAR(128) NOT NULL,      -- 'C:\' , 'F:\' , 'cluster' , node id
    TotalBytes      BIGINT        NOT NULL,
    UsedBytes       BIGINT        NOT NULL,
    FreeBytes       AS (TotalBytes - UsedBytes) PERSISTED,
    UsedPct         AS (CASE WHEN TotalBytes > 0
                            THEN CAST(100.0 * UsedBytes / TotalBytes AS DECIMAL(5,2))
                            ELSE 0 END) PERSISTED
);
GO
CREATE INDEX IX_DiskUsage_Trend ON mon.DiskUsage (Platform, ServerName, VolumeName, CollectedAt);
GO

/*---------------------------------------------------------------------------
  mon.DiskForecast  -  latest computed "days until full" per volume.
  Recomputed by cfg.usp_Refresh_DiskForecast; dashboard reads this table.
---------------------------------------------------------------------------*/
IF OBJECT_ID('mon.DiskForecast') IS NULL
CREATE TABLE mon.DiskForecast
(
    Platform            VARCHAR(20)   NOT NULL,
    ServerName          SYSNAME       NOT NULL,
    VolumeName          NVARCHAR(128) NOT NULL,
    TotalBytes          BIGINT        NOT NULL,
    UsedBytes           BIGINT        NOT NULL,
    UsedPct             DECIMAL(5,2)  NOT NULL,
    GrowthBytesPerDay   BIGINT        NULL,        -- least-squares slope
    DaysToFull          INT           NULL,        -- NULL = flat/shrinking (no risk)
    ProjectedFullDate   DATE          NULL,
    RecommendedAddGB    INT           NULL,        -- to buy ~180 days headroom
    Severity            VARCHAR(10)   NOT NULL,    -- OK / WARN / CRIT
    ComputedAt          DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_DiskForecast PRIMARY KEY (Platform, ServerName, VolumeName)
);
GO

/*---------------------------------------------------------------------------
  cfg.AppOwners  -  the "who do I call" table, editable from the dashboard form.
---------------------------------------------------------------------------*/
IF OBJECT_ID('cfg.AppOwners') IS NULL
CREATE TABLE cfg.AppOwners
(
    AppOwnerID      INT IDENTITY(1,1) PRIMARY KEY,
    ServerName      SYSNAME       NOT NULL,
    DatabaseName    SYSNAME       NOT NULL DEFAULT '(instance)',
    AppName         NVARCHAR(128) NOT NULL,
    Criticality     VARCHAR(10)   NOT NULL DEFAULT 'Tier3'   -- Tier1/Tier2/Tier3
        CONSTRAINT CK_AppOwners_Crit CHECK (Criticality IN ('Tier1','Tier2','Tier3')),
    PrimaryOwner    NVARCHAR(128) NULL,
    SecondaryOwner  NVARCHAR(128) NULL,
    Team            NVARCHAR(128) NULL,
    Email           NVARCHAR(256) NULL,
    OnCallPhone     VARCHAR(40)   NULL,
    Notes           NVARCHAR(1000) NULL,
    UpdatedBy       NVARCHAR(128) NOT NULL DEFAULT SUSER_SNAME(),
    UpdatedAt       DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_AppOwners UNIQUE (ServerName, DatabaseName, AppName)
);
GO

/*---------------------------------------------------------------------------
  cfg.CollectionLog  -  audit of every collector run (success/failure/rowcount)
---------------------------------------------------------------------------*/
IF OBJECT_ID('cfg.CollectionLog') IS NULL
CREATE TABLE cfg.CollectionLog
(
    LogID       BIGINT IDENTITY(1,1) PRIMARY KEY,
    RunAt       DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME(),
    Collector   VARCHAR(40)  NOT NULL,       -- AGSync / DiskUsage / DataLag / Redshift
    ServerName  SYSNAME      NULL,
    Status      VARCHAR(10)  NOT NULL,       -- OK / ERROR
    RowsLoaded  INT          NULL,
    Message     NVARCHAR(2000) NULL
);
GO

PRINT 'Tables created.';
GO
