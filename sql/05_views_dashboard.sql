/*==============================================================================
  DBADash  |  05 - Reporting views (rpt schema)
  ----------------------------------------------------------------------------
  These are the ONLY objects the HTML dashboard / Power BI / SSRS need to read.
  Everything is "latest snapshot" logic so consumers just SELECT * with no
  window functions of their own.
==============================================================================*/
USE [DBADash];
GO
SET NOCOUNT ON;
GO

/*---------------------------------------------------------------------------
  rpt.AGSyncStatus  -  latest AG replica health, with a rolled-up status.
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.AGSyncStatus
AS
WITH latest AS
(
    SELECT *, rn = ROW_NUMBER() OVER (
                 PARTITION BY AGName, DatabaseName, ReplicaServer
                 ORDER BY CollectedAt DESC)
    FROM mon.AGSyncStatus
)
SELECT
    AGName, DatabaseName, ReplicaServer, Role, SyncState, SyncHealth,
    LogSendQueueKB, RedoQueueKB, LastCommitTime, CollectedAt,
    Status = CASE
                WHEN SyncHealth = 'HEALTHY'         AND SyncState = 'SYNCHRONIZED'  THEN 'OK'
                WHEN SyncHealth = 'HEALTHY'         AND SyncState = 'SYNCHRONIZING' THEN 'OK'
                WHEN SyncHealth = 'PARTIALLY_HEALTHY'                               THEN 'WARN'
                ELSE 'CRIT' END
FROM latest
WHERE rn = 1;
GO

/*---------------------------------------------------------------------------
  rpt.DataLag  -  latest lag reading per object (MSSQL AG + Redshift loads).
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.DataLag
AS
WITH latest AS
(
    SELECT *, rn = ROW_NUMBER() OVER (
                 PARTITION BY Platform, ServerName, ObjectName, Metric
                 ORDER BY CollectedAt DESC)
    FROM mon.DataLag
)
SELECT
    Platform, ServerName, ObjectName, Metric, LagSeconds, Detail, CollectedAt,
    LagMinutes = CAST(LagSeconds / 60.0 AS DECIMAL(10,1)),
    Status = CASE
                WHEN LagSeconds IS NULL          THEN 'WARN'
                WHEN LagSeconds <= 60            THEN 'OK'
                WHEN LagSeconds <= 900           THEN 'WARN'   -- <= 15 min
                ELSE 'CRIT' END
FROM latest
WHERE rn = 1;
GO

/*---------------------------------------------------------------------------
  rpt.DiskForecast  -  disk expansion forecast, human-friendly units.
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.DiskForecast
AS
SELECT
    Platform, ServerName, VolumeName,
    TotalGB   = CAST(TotalBytes / 1073741824.0 AS DECIMAL(12,1)),
    UsedGB    = CAST(UsedBytes  / 1073741824.0 AS DECIMAL(12,1)),
    FreeGB    = CAST((TotalBytes - UsedBytes) / 1073741824.0 AS DECIMAL(12,1)),
    UsedPct,
    GrowthGBPerDay = CAST(GrowthBytesPerDay / 1073741824.0 AS DECIMAL(12,2)),
    DaysToFull, ProjectedFullDate, RecommendedAddGB, Severity, ComputedAt
FROM mon.DiskForecast;
GO

/*---------------------------------------------------------------------------
  rpt.AppOwners  -  contact directory (straight passthrough for the form/grid).
---------------------------------------------------------------------------*/
CREATE OR ALTER VIEW rpt.AppOwners
AS
SELECT AppOwnerID, ServerName, DatabaseName, AppName, Criticality,
       PrimaryOwner, SecondaryOwner, Team, Email, OnCallPhone, Notes,
       UpdatedBy, UpdatedAt
FROM cfg.AppOwners;
GO

/*---------------------------------------------------------------------------
  rpt.Overview  -  single-row KPI header for the top of the dashboard.
---------------------------------------------------------------------------*/
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
    AppsWithoutOwner   = (SELECT COUNT(*) FROM cfg.Servers s
                          WHERE s.IsActive = 1
                            AND NOT EXISTS (SELECT 1 FROM cfg.AppOwners a
                                            WHERE a.ServerName = s.ServerName)),
    LastCollection     = (SELECT MAX(RunAt) FROM cfg.CollectionLog WHERE Status = 'OK');
GO

PRINT 'Reporting views created.';
GO
