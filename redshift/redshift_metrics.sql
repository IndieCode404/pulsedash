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

--==RS_LOGINS==--
-- Failed authentications, last 24h. Must return: EventTime, Message.
SELECT
    recordtime AS EventTime,
    LEFT('Failed auth: user=' || TRIM(username) || ' from ' || TRIM(remotehost), 500) AS Message
FROM stl_connection_log
WHERE event = 'authentication failure'
  AND recordtime > DATEADD(day, -1, GETDATE());
