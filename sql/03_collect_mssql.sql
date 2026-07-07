/*==============================================================================
  DBADash  |  03 - MSSQL collection queries (RUN ON EACH TARGET INSTANCE)
  ----------------------------------------------------------------------------
  These SELECTs are executed against every MSSQL instance registered in your
  CMS group by deploy\Collect-All.ps1. They have NO dependency on the DBADash
  database, so they are safe to run anywhere. The PowerShell collector adds the
  CollectedAt / ServerName columns and bulk-loads the results into DBADash.

  This file is also runnable by hand in SSMS against a single instance if you
  just want to eyeball the raw data.
==============================================================================*/
SET NOCOUNT ON;

/*---------------------------------------------------------------------------
  QUERY 1 :: AG SYNC STATUS
  One row per (AG, database, replica). Includes last_commit_time so the
  central view can compute how many seconds each secondary trails the primary.
---------------------------------------------------------------------------*/
SELECT
    AGName          = ag.name,
    DatabaseName    = DB_NAME(drs.database_id),
    ReplicaServer   = ar.replica_server_name,
    IsPrimary       = CONVERT(bit, drs.is_primary_replica),
    Role            = CASE WHEN drs.is_primary_replica = 1 THEN 'PRIMARY' ELSE 'SECONDARY' END,
    SyncState       = drs.synchronization_state_desc,
    SyncHealth      = drs.synchronization_health_desc,
    LogSendQueueKB  = drs.log_send_queue_size,
    RedoQueueKB     = drs.redo_queue_size,
    LastCommitTime  = drs.last_commit_time,
    LastHardenedTime= drs.last_hardened_time,
    LastRedoneTime  = drs.last_redone_time
FROM sys.dm_hadr_database_replica_states AS drs
JOIN sys.availability_replicas AS ar  ON ar.replica_id = drs.replica_id
JOIN sys.availability_groups   AS ag  ON ag.group_id   = ar.group_id;
-- (returns zero rows on a standalone instance - that's fine, it's just skipped)


/*---------------------------------------------------------------------------
  QUERY 2 :: DISK / VOLUME USAGE
  One row per distinct OS volume that hosts a database file. total/available
  bytes come straight from the OS via dm_os_volume_stats.
---------------------------------------------------------------------------*/
SELECT DISTINCT
    VolumeName = vs.volume_mount_point,
    TotalBytes = vs.total_bytes,
    UsedBytes  = vs.total_bytes - vs.available_bytes
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs;


/*---------------------------------------------------------------------------
  QUERY 3 :: AG DATA LAG (seconds a secondary trails the primary)
  Pairs each secondary's last_commit_time against the primary's for the same
  database. Positive LagSeconds = seconds of data the secondary is behind.
  Also flags redo backlog. Runs correctly from the PRIMARY replica.
---------------------------------------------------------------------------*/
WITH r AS
(
    SELECT
        ag.name                         AS AGName,
        DB_NAME(drs.database_id)        AS DatabaseName,
        ar.replica_server_name          AS ReplicaServer,
        drs.is_primary_replica          AS IsPrimary,
        drs.last_commit_time            AS LastCommitTime,
        drs.redo_queue_size             AS RedoQueueKB
    FROM sys.dm_hadr_database_replica_states AS drs
    JOIN sys.availability_replicas AS ar ON ar.replica_id = drs.replica_id
    JOIN sys.availability_groups   AS ag ON ag.group_id   = ar.group_id
),
p AS (SELECT AGName, DatabaseName, LastCommitTime FROM r WHERE IsPrimary = 1)
SELECT
    ObjectName = CONCAT('AG:', s.DatabaseName, '@', s.ReplicaServer),
    LagSeconds = DATEDIFF(SECOND, s.LastCommitTime, p.LastCommitTime),
    Metric     = 'ag_redo_lag',
    Detail     = CONCAT('AG=', s.AGName, '; RedoQueueKB=', ISNULL(s.RedoQueueKB, 0))
FROM r AS s
JOIN p     ON p.AGName = s.AGName AND p.DatabaseName = s.DatabaseName
WHERE s.IsPrimary = 0;
