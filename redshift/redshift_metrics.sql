/*==============================================================================
  DBADash  |  Redshift metric queries  (run BY Collect-Redshift.ps1)
  ----------------------------------------------------------------------------
  Collect-Redshift.ps1 runs each block below against your cluster and loads the
  results into the DBADash central DB (mon.DiskUsage / mon.DataLag).

  Blocks are delimited by  --==<NAME>==--  markers so the collector can pull
  each one out by name. Edit the SQL to match your cluster; the shapes
  (column names) are what the collector expects.
==============================================================================*/

--==DISK==--
-- Cluster disk usage rolled up across all data slices.
-- stv_partitions.capacity/used are counts of 1 MB blocks; part_begin=0 gives
-- exactly one row per physical partition (avoids double counting).
SELECT
    volume_name  AS VolumeName,
    total_bytes  AS TotalBytes,
    used_bytes   AS UsedBytes
FROM (
    SELECT
        'cluster'::varchar                       AS volume_name,
        SUM(capacity)::bigint * 1048576          AS total_bytes,
        SUM(used)::bigint     * 1048576          AS used_bytes
    FROM stv_partitions
    WHERE part_begin = 0
) t;

--==FRESHNESS==--
-- Best-effort ETL/load freshness: seconds since the last row was inserted into
-- each table via COPY/INSERT in the last 2 days. EDIT THIS to match how your
-- pipeline lands data (e.g. join to a control table, or use SYS_LOAD_HISTORY
-- on RA3/Serverless). Must return: ObjectName, LagSeconds.
SELECT
    TRIM(c.relname)                                   AS ObjectName,
    DATEDIFF(second, MAX(q.endtime), GETDATE())       AS LagSeconds
FROM stl_insert  i
JOIN stl_query   q ON q.query = i.query
JOIN stv_tbl_perm p ON p.id   = i.tbl
JOIN pg_class    c ON c.oid   = p.id
WHERE q.endtime > DATEADD(day, -2, GETDATE())
GROUP BY c.relname;

--==TABLE_SIZE==--
-- Per-table size for the growth chart. svv_table_info.size is in 1 MB blocks.
-- Must return: ObjectName, SizeBytes.
SELECT
    TRIM("schema") || '.' || TRIM("table")   AS ObjectName,
    size::bigint * 1048576                    AS SizeBytes
FROM svv_table_info;

--==TABLE_HEALTH==--
-- Vacuum/analyze debt: tables that are heavily unsorted or have stale stats.
-- Must return: TableName, UnsortedPct, StatsOffPct, TableRows.
SELECT
    TRIM("schema") || '.' || TRIM("table")  AS TableName,
    COALESCE(unsorted, 0)                    AS UnsortedPct,
    COALESCE(stats_off, 0)                   AS StatsOffPct,
    tbl_rows::bigint                         AS TableRows
FROM svv_table_info
WHERE COALESCE(unsorted,0) >= 10 OR COALESCE(stats_off,0) >= 10
ORDER BY GREATEST(COALESCE(unsorted,0), COALESCE(stats_off,0)) DESC
LIMIT 100;

--==ACTIVITY==--
-- Long-running queries (> 60s). Must return the mon.QuerySnapshot shape.
SELECT
    pid                          AS SessionID,
    0                            AS BlockedBy,
    TRIM(status)                 AS Status,
    NULL::varchar                AS WaitType,
    duration / 1000000           AS DurationSec,
    TRIM(db_name)                AS DatabaseName,
    TRIM(user_name)              AS LoginName,
    NULL::varchar                AS HostName,
    NULL::varchar                AS ProgramName,
    SUBSTRING(query, 1, 500)     AS QueryText
FROM stv_recents
WHERE status = 'Running' AND duration > 60000000;

--==RS_VITALS==--
-- Cluster vitals -> mon.HealthMetric. Must return: MetricName, MetricValue, Detail.
SELECT 'queued_queries'::varchar AS MetricName,
       COUNT(*)::float AS MetricValue, NULL::varchar AS Detail
FROM stv_wlm_query_state WHERE state LIKE 'Queued%'
UNION ALL
SELECT 'db_connections', COUNT(*)::float, NULL FROM stv_sessions
UNION ALL
SELECT 'load_errors_24h', COUNT(*)::float, NULL
FROM stl_load_errors WHERE starttime > DATEADD(day, -1, GETDATE());

--==TABLE_SCAN==--
-- When was each table last READ? STL only keeps a few days, but DBADash
-- snapshots this every cycle so central history accumulates -> stale-table
-- detection. Must return: TableName, LastScanned.
SELECT
    TRIM(ti."schema") || '.' || TRIM(ti."table") AS TableName,
    MAX(s.endtime)                                AS LastScanned
FROM stl_scan s
JOIN svv_table_info ti ON ti.table_id = s.tbl
WHERE s.userid > 1
GROUP BY 1;

--==SPECTRUM==--
-- Spectrum usage by external table, last 24h (~$5/TB scanned).
-- Must return: ExternalTable, QueryCount, TBScanned.
SELECT
    COALESCE(NULLIF(TRIM(external_table_name),''),'(unknown)') AS ExternalTable,
    COUNT(DISTINCT query)                                       AS QueryCount,
    SUM(s3_scanned_bytes)::float / 1e12                         AS TBScanned
FROM svl_s3query_summary
WHERE starttime > DATEADD(day, -1, GETDATE())
GROUP BY 1
ORDER BY 3 DESC
LIMIT 50;

--==RS_LOGINS==--
-- Failed authentications, last 24h. Must return: EventTime, Message.
SELECT
    recordtime AS EventTime,
    LEFT('Failed auth: user=' || TRIM(username) || ' from ' || TRIM(remotehost), 500) AS Message
FROM stl_connection_log
WHERE event = 'authentication failure'
  AND recordtime > DATEADD(day, -1, GETDATE());

--==LOCKS==--
-- Lock waits for the Advisor (long-block detection). Each row = one session
-- waiting on a lock, matched to the blocker holding it. Must return the
-- mon.LockWait shape: WaiterPid, WaiterUser, Relation, WaitMinutes,
-- WaiterQuery, BlockerPid, BlockerUser, BlockerLockMode, BlockerIdleInTxn,
-- BlockerQuery, ConflictCount24h.
--
-- svv_transactions has one row per held/requested lock; granted='f' is a waiter.
-- We match each waiter to a granted holder of the same relation, keep the
-- oldest such blocker, and flag the blocker "idle in transaction" when it has
-- no row in stv_inflight (holding a lock with nothing running). WaitMinutes is
-- approximated from the blocked transaction's start time. EDIT if your cluster
-- version exposes these differently (Serverless uses SYS_* views).
SELECT
    waiter_pid                                       AS WaiterPid,
    waiter_user                                      AS WaiterUser,
    relation_name                                    AS Relation,
    wait_minutes                                     AS WaitMinutes,
    SUBSTRING(TRIM(waiter_sql), 1, 500)              AS WaiterQuery,
    blocker_pid                                      AS BlockerPid,
    blocker_user                                     AS BlockerUser,
    blocker_lock_mode                                AS BlockerLockMode,
    blocker_idle_in_txn                              AS BlockerIdleInTxn,
    SUBSTRING(TRIM(blocker_sql), 1, 500)             AS BlockerQuery,
    conflict_count_24h                               AS ConflictCount24h
FROM (
    SELECT
        w.pid                                         AS waiter_pid,
        TRIM(w.txn_owner)                             AS waiter_user,
        COALESCE(TRIM(c.relname), w.relation::varchar) AS relation_name,
        DATEDIFF(minute, w.txn_start, GETDATE())      AS wait_minutes,
        rw.query                                      AS waiter_sql,
        b.pid                                         AS blocker_pid,
        TRIM(b.txn_owner)                             AS blocker_user,
        TRIM(b.lock_mode)                             AS blocker_lock_mode,
        CASE WHEN bi.pid IS NULL THEN 1 ELSE 0 END    AS blocker_idle_in_txn,
        bi.text                                       AS blocker_sql,
        COALESCE(cf.cnt, 0)                           AS conflict_count_24h,
        ROW_NUMBER() OVER (PARTITION BY w.pid, w.relation ORDER BY b.txn_start) AS rn
    FROM svv_transactions w
    JOIN svv_transactions b
      ON b.relation = w.relation AND b.granted = 't' AND b.pid <> w.pid
    LEFT JOIN pg_class      c  ON c.oid = w.relation
    LEFT JOIN stv_recents   rw ON rw.pid = w.pid AND rw.status = 'Running'
    LEFT JOIN stv_inflight  bi ON bi.pid = b.pid
    LEFT JOIN (SELECT table_id, COUNT(*) AS cnt
               FROM stl_tr_conflict
               WHERE xact_start_ts > DATEADD(day, -1, GETDATE())
               GROUP BY table_id) cf ON cf.table_id = w.relation
    WHERE w.granted = 'f'
) t
WHERE rn = 1 AND wait_minutes >= 5;   -- snapshot early; the engine flags >= 30 min

--==COST==--
-- Cost DRIVERS for anomaly detection. Each row = one metric for the last ~24h.
-- Must return: MetricName, MetricValue, MetricUnit. EDIT to match your edition
-- (provisioned vs Serverless vs Spectrum). Blocks that don't apply return 0.

-- (1) Spectrum data scanned - billed ~$5/TB. (svl_s3query_summary is provisioned.)
SELECT 'spectrum_tb_1d'::varchar AS MetricName,
       ROUND(COALESCE(SUM(s3_scanned_bytes),0)::numeric / 1e12, 4) AS MetricValue,
       'TB'::varchar AS MetricUnit
FROM svl_s3query_summary
WHERE starttime > DATEADD(day, -1, GETDATE())

UNION ALL
-- (2) Total data scanned by queries in the last day (RA3 / scaling proxy).
SELECT 'bytes_scanned_tb_1d',
       ROUND(COALESCE(SUM(scan_size_bytes),0)::numeric / 1e12, 4),
       'TB'
FROM sys_query_history
WHERE start_time > DATEADD(day, -1, GETDATE())

UNION ALL
-- (3) Serverless RPU-hours in the last day (comment out on provisioned clusters).
--     Uncomment if you run Redshift Serverless:
-- SELECT 'serverless_rpu_hours_1d',
--        ROUND(COALESCE(SUM(charged_seconds * compute_capacity),0)::numeric / 3600, 3),
--        'RPU-hr'
-- FROM sys_serverless_usage
-- WHERE end_time > DATEADD(day, -1, GETDATE())
-- UNION ALL
-- (4) Managed storage currently used (GB).
SELECT 'storage_gb',
       ROUND(SUM(used)::numeric / 1024, 1),      -- stv_partitions.used is in 1 MB blocks
       'GB'
FROM stv_partitions
WHERE part_begin = 0;
