<#
    DBADash | Collect-All.ps1   (the job the SQL Agent schedule runs)
    ---------------------------------------------------------------------------
    1. Fan out to every MSSQL instance in the CMS group and collect:
         - AG sync status   -> mon.AGSyncStatus
         - AG data lag       -> mon.DataLag
         - Disk/volume usage -> mon.DiskUsage
    2. Collect each Redshift cluster (delegates to Collect-Redshift.ps1).
    3. Refresh the disk forecast and purge old history.

    Every instance is collected independently: one unreachable server logs an
    ERROR row and the run continues.
#>
[CmdletBinding()]
param([string]$ConfigPath = "$PSScriptRoot\config\dbadash.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

$cfg         = Get-DbaDashConfig -Path $ConfigPath
$centralConn = Get-SqlConnString -Instance $cfg.central.sqlInstance -Database $cfg.central.database `
                                 -User $cfg.central.user -Password $cfg.central.password

# ---- The three target-side queries (kept in sync with sql\03_collect_mssql.sql) ----
$Q_AGSYNC = @"
SELECT AGName=ag.name, DatabaseName=DB_NAME(drs.database_id), ReplicaServer=ar.replica_server_name,
       IsPrimary=CONVERT(bit,drs.is_primary_replica),
       Role=CASE WHEN drs.is_primary_replica=1 THEN 'PRIMARY' ELSE 'SECONDARY' END,
       SyncState=drs.synchronization_state_desc, SyncHealth=drs.synchronization_health_desc,
       LogSendQueueKB=drs.log_send_queue_size, RedoQueueKB=drs.redo_queue_size,
       LastCommitTime=drs.last_commit_time, LastHardenedTime=drs.last_hardened_time,
       LastRedoneTime=drs.last_redone_time
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON ar.replica_id=drs.replica_id
JOIN sys.availability_groups   ag ON ag.group_id=ar.group_id;
"@

$Q_DISK = @"
SELECT DISTINCT VolumeName=vs.volume_mount_point, TotalBytes=vs.total_bytes,
       UsedBytes=vs.total_bytes - vs.available_bytes
FROM sys.master_files mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs;
"@

$Q_DBSIZE = @"
SELECT ObjectType='database', ObjectName=DB_NAME(database_id),
       SizeBytes=SUM(CAST(size AS bigint)) * 8 * 1024
FROM sys.master_files WHERE type IN (0,1) GROUP BY database_id;
"@

$Q_LAG = @"
WITH r AS (SELECT ag.name AGName, DB_NAME(drs.database_id) DatabaseName, ar.replica_server_name ReplicaServer,
                  drs.is_primary_replica IsPrimary, drs.last_commit_time LastCommitTime, drs.redo_queue_size RedoQueueKB
           FROM sys.dm_hadr_database_replica_states drs
           JOIN sys.availability_replicas ar ON ar.replica_id=drs.replica_id
           JOIN sys.availability_groups   ag ON ag.group_id=ar.group_id),
     p AS (SELECT AGName, DatabaseName, LastCommitTime FROM r WHERE IsPrimary=1)
SELECT ObjectName=CONCAT('AG:',s.DatabaseName,'@',s.ReplicaServer),
       LagSeconds=DATEDIFF(SECOND,s.LastCommitTime,p.LastCommitTime), Metric='ag_redo_lag',
       Detail=CONCAT('AG=',s.AGName,'; RedoQueueKB=',ISNULL(s.RedoQueueKB,0))
FROM r s JOIN p ON p.AGName=s.AGName AND p.DatabaseName=s.DatabaseName WHERE s.IsPrimary=0;
"@

$Q_BACKUP = @"
SELECT DatabaseName=d.name, RecoveryModel=d.recovery_model_desc, StateDesc=d.state_desc,
       LastFullBackup=MAX(CASE WHEN b.type='D' THEN b.backup_finish_date END),
       LastDiffBackup=MAX(CASE WHEN b.type='I' THEN b.backup_finish_date END),
       LastLogBackup =MAX(CASE WHEN b.type='L' THEN b.backup_finish_date END),
       LastGoodCheckDb=CONVERT(datetime2(0), DATABASEPROPERTYEX(d.name,'LastGoodCheckDbTime')),
       PageVerify=d.page_verify_option_desc,
       IsAutoShrink=d.is_auto_shrink_on
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b
       ON b.database_name = d.name
      AND b.is_copy_only = 0                 -- copy-only backups don't reset RPO
      AND b.is_snapshot  = 0                 -- neither do VSS snapshot backups
WHERE d.database_id <> 2                     -- skip tempdb
GROUP BY d.name, d.recovery_model_desc, d.state_desc, d.page_verify_option_desc, d.is_auto_shrink_on;
"@

$Q_JOBS = @"
SELECT JobName=j.name, StepName=h.step_name,
       RunAt=msdb.dbo.agent_datetime(h.run_date,h.run_time), Message=LEFT(h.message,600)
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id=h.job_id
WHERE h.run_status=0 AND h.step_id>0
  AND msdb.dbo.agent_datetime(h.run_date,h.run_time) > DATEADD(HOUR,-24,GETDATE());
"@

$Q_VITALS = @"
-- Worst VLF count needs sys.dm_db_log_info (2016 SP2+); read it in isolated
-- dynamic SQL so an older target degrades to "no VLF metric" instead of failing.
DECLARE @maxvlf float = NULL;
BEGIN TRY
    EXEC sys.sp_executesql
        N'SELECT @m = ISNULL(MAX(cnt),0)
          FROM (SELECT CAST(COUNT(*) AS float) cnt FROM sys.databases d
                CROSS APPLY sys.dm_db_log_info(d.database_id) GROUP BY d.database_id) z',
        N'@m float OUTPUT', @m = @maxvlf OUTPUT;
END TRY BEGIN CATCH SET @maxvlf = NULL; END CATCH;

SELECT MetricName='page_life_expectancy', MetricValue=CAST(cntr_value AS float), Detail=CAST(NULL AS nvarchar(256))
FROM sys.dm_os_performance_counters
WHERE counter_name='Page life expectancy' AND object_name LIKE '%:Buffer Manager%'
UNION ALL
SELECT 'memory_grants_pending', CAST(cntr_value AS float), NULL
FROM sys.dm_os_performance_counters WHERE counter_name='Memory Grants Pending'
UNION ALL
SELECT 'user_sessions', (SELECT CAST(COUNT(*) AS float) FROM sys.dm_exec_sessions WHERE is_user_process=1), NULL
UNION ALL
SELECT 'blocked_sessions', (SELECT CAST(COUNT(*) AS float) FROM sys.dm_exec_requests WHERE blocking_session_id<>0), NULL
UNION ALL
SELECT 'uptime_hours', (SELECT CAST(DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) AS float) FROM sys.dm_os_sys_info), NULL
UNION ALL
-- SQL Server CPU % from the scheduler-monitor ring buffer (last sample)
SELECT 'cpu_pct',
       CAST(ISNULL((
         SELECT TOP (1)
                rec.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]','int')
         FROM (SELECT CONVERT(xml, record) AS rec
               FROM sys.dm_os_ring_buffers
               WHERE ring_buffer_type='RING_BUFFER_SCHEDULER_MONITOR'
                 AND record LIKE '%<SystemHealth>%') AS t
         ORDER BY rec.value('(./Record/@time)[1]','bigint') DESC), 0) AS float), NULL
UNION ALL
-- corruption early-warning: any rows here mean SQL hit a bad page
SELECT 'suspect_pages', (SELECT CAST(COUNT(*) AS float) FROM msdb.dbo.suspect_pages), NULL
UNION ALL
-- cumulative since restart (trend it; a jump between collections = new deadlocks)
SELECT 'deadlocks_total',
       (SELECT CAST(cntr_value AS float) FROM sys.dm_os_performance_counters
        WHERE counter_name='Number of Deadlocks/sec' AND instance_name='_Total'), NULL
UNION ALL
-- tempdb allocated size (GB) - the "why is tempdb huge" early warning
SELECT 'tempdb_used_gb',
       (SELECT CAST(SUM(user_object_reserved_page_count + internal_object_reserved_page_count
                       + version_store_reserved_page_count + mixed_extent_page_count) * 8 / 1048576.0 AS float)
        FROM tempdb.sys.dm_db_file_space_usage), NULL
UNION ALL
-- tempdb version store (GB) - long-open transactions / snapshot isolation bloat
SELECT 'tempdb_version_store_gb',
       (SELECT CAST(SUM(version_store_reserved_page_count) * 8 / 1048576.0 AS float)
        FROM tempdb.sys.dm_db_file_space_usage), NULL
UNION ALL
-- worst VLF count across databases (only emitted where dm_db_log_info exists)
SELECT 'max_vlf_count', @maxvlf, NULL WHERE @maxvlf IS NOT NULL;
"@

$Q_ACTIVITY = @"
SELECT SessionID=r.session_id, BlockedBy=r.blocking_session_id, Status=r.status,
       WaitType=r.wait_type, DurationSec=DATEDIFF(SECOND,r.start_time,GETDATE()),
       DatabaseName=DB_NAME(r.database_id), LoginName=s.login_name, HostName=s.host_name,
       ProgramName=LEFT(s.program_name,160), QueryText=LEFT(t.text,500)
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id=r.session_id
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE s.is_user_process=1
  AND (r.blocking_session_id<>0 OR DATEDIFF(SECOND,r.start_time,GETDATE())>60);
"@

$Q_WAITS = @"
SELECT TOP (10) WaitType=wait_type, WaitTimeMs=wait_time_ms,
       WaitPct=CAST(100.0*wait_time_ms/NULLIF(SUM(wait_time_ms) OVER(),0) AS DECIMAL(5,1))
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN ('CLR_SEMAPHORE','LAZYWRITER_SLEEP','RESOURCE_QUEUE','SLEEP_TASK','SLEEP_SYSTEMTASK',
 'SQLTRACE_BUFFER_FLUSH','WAITFOR','LOGMGR_QUEUE','CHECKPOINT_QUEUE','REQUEST_FOR_DEADLOCK_SEARCH',
 'XE_TIMER_EVENT','BROKER_TO_FLUSH','BROKER_TASK_STOP','CLR_MANUAL_EVENT','CLR_AUTO_EVENT',
 'DISPATCHER_QUEUE_SEMAPHORE','FT_IFTS_SCHEDULER_IDLE_WAIT','XE_DISPATCHER_WAIT','XE_DISPATCHER_JOIN',
 'BROKER_EVENTHANDLER','TRACEWRITE','FT_IFTSHC_MUTEX','SQLTRACE_INCREMENTAL_FLUSH_SLEEP','BROKER_RECEIVE_WAITFOR',
 'ONDEMAND_TASK_QUEUE','DBMIRROR_EVENTS_QUEUE','DBMIRRORING_CMD','BROKER_TRANSMITTER','SQLTRACE_WAIT_ENTRIES',
 'SLEEP_BPOOL_FLUSH','SQLTRACE_LOCK','DIRTY_PAGE_POLL','HADR_FILESTREAM_IOMGR_IOCOMPLETION','SP_SERVER_DIAGNOSTICS_SLEEP',
 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP','WAIT_XTP_HOST_WAIT')
  AND wait_time_ms > 0
ORDER BY wait_time_ms DESC;
"@

$Q_TOPQ = @"
SELECT TOP (10)
       DatabaseName=DB_NAME(t.dbid), QueryText=LEFT(t.text,500),
       ExecCount=qs.execution_count,
       TotalCpuMs=qs.total_worker_time/1000,
       AvgCpuMs=qs.total_worker_time/NULLIF(qs.execution_count,0)/1000,
       AvgDurMs=qs.total_elapsed_time/NULLIF(qs.execution_count,0)/1000,
       AvgReads=qs.total_logical_reads/NULLIF(qs.execution_count,0),
       LastExec=qs.last_execution_time
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) t
WHERE qs.last_execution_time > DATEADD(DAY,-1,GETDATE())
ORDER BY qs.total_worker_time DESC;
"@

# Failed logins from the error log (needs securityadmin; degrades to 0 rows without it)
$Q_FAILEDLOGIN = @"
DECLARE @log TABLE (LogDate datetime, ProcessInfo nvarchar(50), LogText nvarchar(3999));
BEGIN TRY
    INSERT @log EXEC master.dbo.xp_readerrorlog 0, 1, N'Login failed';
    INSERT @log EXEC master.dbo.xp_readerrorlog 1, 1, N'Login failed';
END TRY BEGIN CATCH END CATCH;
SELECT EventTime=CONVERT(datetime2(0), LogDate), Message=LEFT(LogText,500)
FROM @log WHERE LogDate > DATEADD(HOUR,-24,GETDATE());
"@

$Q_LOGINACT = @"
SELECT LoginName=login_name, HostName=host_name, ProgramName=LEFT(program_name,160),
       SessionCount=COUNT(*), LastLogin=MAX(login_time)
FROM sys.dm_exec_sessions
WHERE is_user_process=1
GROUP BY login_name, host_name, LEFT(program_name,160);
"@

# Patch / build / version - "what SP + CU am I on" (SERVERPROPERTY + host info).
# Min supported target: SQL 2012. sys.dm_os_host_info is 2017+, so it is read via
# isolated dynamic SQL wrapped in TRY/CATCH - on older targets host info comes
# back NULL instead of compile-failing (which would abort the whole cycle).
$Q_SERVERINFO = @"
DECLARE @hostPlatform nvarchar(40) = NULL, @osVersion nvarchar(120) = NULL;
BEGIN TRY
    EXEC sys.sp_executesql
        N'SELECT @hp = host_platform,
                 @os = LEFT(host_distribution + '' '' + host_release, 120)
          FROM sys.dm_os_host_info',
        N'@hp nvarchar(40) OUTPUT, @os nvarchar(120) OUTPUT',
        @hp = @hostPlatform OUTPUT, @os = @osVersion OUTPUT;
END TRY BEGIN CATCH END CATCH;

SELECT
    ProductVersion     = CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)),
    ProductLevel       = CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(20)),
    ProductUpdateLevel = CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(20)),
    Edition            = CAST(SERVERPROPERTY('Edition') AS nvarchar(80)),
    ProductMajor       = CAST(SERVERPROPERTY('ProductMajorVersion') AS nvarchar(40)),
    HostPlatform       = @hostPlatform,
    OSVersion          = @osVersion,
    IsClustered        = CAST(SERVERPROPERTY('IsClustered') AS bit),
    IsHadrEnabled      = CAST(SERVERPROPERTY('IsHadrEnabled') AS bit),
    StartTime          = (SELECT sqlserver_start_time FROM sys.dm_os_sys_info),
    CpuCount           = (SELECT cpu_count FROM sys.dm_os_sys_info),
    PhysicalMemoryMB   = (SELECT physical_memory_kb/1024 FROM sys.dm_os_sys_info);
"@

# Configuration drift - the sp_Blitz "Configuration" category, one row per check.
$Q_CONFIG = @"
;WITH c AS (SELECT name, CAST(value_in_use AS bigint) v FROM sys.configurations),
      si AS (SELECT cpu_count FROM sys.dm_os_sys_info),
      sa AS (SELECT name, is_disabled FROM sys.server_principals WHERE sid = 0x01)
SELECT ConfigItem, CurrentValue, RecommendedValue, Status, Detail FROM (
    SELECT 'max degree of parallelism' ConfigItem,
           CAST((SELECT v FROM c WHERE name='max degree of parallelism') AS nvarchar(100)) CurrentValue,
           '4-8 (not 0 on >8 cores)' RecommendedValue,
           CASE WHEN (SELECT v FROM c WHERE name='max degree of parallelism')=0
                 AND (SELECT cpu_count FROM si) > 8 THEN 'WARN' ELSE 'OK' END Status,
           'MAXDOP 0 lets a single query grab every core.' Detail
    UNION ALL SELECT 'cost threshold for parallelism',
           CAST((SELECT v FROM c WHERE name='cost threshold for parallelism') AS nvarchar(100)), '>= 50',
           CASE WHEN (SELECT v FROM c WHERE name='cost threshold for parallelism') <= 5 THEN 'WARN' ELSE 'OK' END,
           'Default 5 sends even trivial queries parallel.'
    UNION ALL SELECT 'max server memory (MB)',
           CAST((SELECT v FROM c WHERE name='max server memory (MB)') AS nvarchar(100)), 'below physical RAM',
           CASE WHEN (SELECT v FROM c WHERE name='max server memory (MB)') >= 2147483647 THEN 'WARN' ELSE 'OK' END,
           'Unlimited lets SQL Server starve the OS.'
    UNION ALL SELECT 'xp_cmdshell',
           CAST((SELECT v FROM c WHERE name='xp_cmdshell') AS nvarchar(100)), '0 (off)',
           CASE WHEN (SELECT v FROM c WHERE name='xp_cmdshell') = 1 THEN 'WARN' ELSE 'OK' END,
           'Shell-command surface; leave off unless required.'
    UNION ALL SELECT 'optimize for ad hoc workloads',
           CAST((SELECT v FROM c WHERE name='optimize for ad hoc workloads') AS nvarchar(100)), '1 (on)',
           CASE WHEN (SELECT v FROM c WHERE name='optimize for ad hoc workloads') = 0 THEN 'WARN' ELSE 'OK' END,
           'Off = single-use plans bloat the plan cache.'
    UNION ALL SELECT 'backup compression default',
           CAST((SELECT v FROM c WHERE name='backup compression default') AS nvarchar(100)), '1 (on)',
           CASE WHEN (SELECT v FROM c WHERE name='backup compression default') = 0 THEN 'WARN' ELSE 'OK' END,
           'On = smaller, faster backups.'
    UNION ALL SELECT 'sa login',
           CASE WHEN (SELECT is_disabled FROM sa)=1 THEN 'disabled' ELSE 'ENABLED' END
             + CASE WHEN (SELECT name FROM sa)='sa' THEN ', name=sa' ELSE ', renamed' END,
           'disabled or renamed',
           CASE WHEN (SELECT is_disabled FROM sa)=0 AND (SELECT name FROM sa)='sa' THEN 'WARN' ELSE 'OK' END,
           'The well-known sa account is a brute-force target.'
    UNION ALL SELECT 'sysadmin members',
           CAST((SELECT COUNT(*) FROM sys.server_role_members m
                 JOIN sys.server_principals r ON r.principal_id=m.role_principal_id
                 WHERE r.name='sysadmin') AS nvarchar(100)), '<= 5',
           CASE WHEN (SELECT COUNT(*) FROM sys.server_role_members m
                      JOIN sys.server_principals r ON r.principal_id=m.role_principal_id
                      WHERE r.name='sysadmin') > 5 THEN 'WARN' ELSE 'OK' END,
           'Every sysadmin can do anything; keep the list short.'
) x;
"@

# Access control - logins/groups classified by the access they hold.
$Q_PRINCIPALS = @"
;WITH rm AS (
    SELECT m.member_principal_id, RoleName = r.name
    FROM sys.server_role_members m
    JOIN sys.server_principals r ON r.principal_id = m.role_principal_id
)
SELECT
    PrincipalName = sp.name,
    PrincipalType = sp.type_desc,
    IsDisabled    = sp.is_disabled,
    CreateDate    = CAST(sp.create_date AS datetime2(0)),
    LastModified  = CAST(sp.modify_date AS datetime2(0)),
    ServerRoles   = STUFF((SELECT ',' + RoleName FROM rm WHERE rm.member_principal_id = sp.principal_id
                           FOR XML PATH('')), 1, 1, ''),
    AccessType = CASE
        WHEN sp.is_disabled = 1 THEN 'Disabled'
        WHEN EXISTS (SELECT 1 FROM rm WHERE rm.member_principal_id=sp.principal_id AND rm.RoleName='sysadmin') THEN 'Sysadmin'
        WHEN EXISTS (SELECT 1 FROM rm WHERE rm.member_principal_id=sp.principal_id AND rm.RoleName='securityadmin') THEN 'Security admin'
        WHEN EXISTS (SELECT 1 FROM rm WHERE rm.member_principal_id=sp.principal_id
                     AND rm.RoleName IN ('serveradmin','processadmin','setupadmin')) THEN 'Elevated'
        WHEN EXISTS (SELECT 1 FROM rm WHERE rm.member_principal_id=sp.principal_id
                     AND rm.RoleName IN ('dbcreator','bulkadmin','diskadmin')) THEN 'Standard'
        ELSE 'Connect-only' END
FROM sys.server_principals sp
WHERE sp.type IN ('S','U','G')       -- SQL login / Windows login / Windows group
  AND sp.name NOT LIKE '##%';        -- skip internal certificate principals
"@

# File I/O latency - the classic storage-bottleneck finder (avg ms/IO per file).
$Q_FILEIO = @"
SELECT TOP (50)
    DatabaseName = DB_NAME(vfs.database_id),
    FileType     = mf.type_desc,
    ReadLatencyMs  = CAST(CASE WHEN vfs.num_of_reads  = 0 THEN 0 ELSE 1.0*vfs.io_stall_read_ms /vfs.num_of_reads  END AS decimal(10,1)),
    WriteLatencyMs = CAST(CASE WHEN vfs.num_of_writes = 0 THEN 0 ELSE 1.0*vfs.io_stall_write_ms/vfs.num_of_writes END AS decimal(10,1)),
    AvgLatencyMs   = CAST(CASE WHEN (vfs.num_of_reads+vfs.num_of_writes)=0 THEN 0
                               ELSE 1.0*vfs.io_stall/(vfs.num_of_reads+vfs.num_of_writes) END AS decimal(10,1)),
    SizeMB       = vfs.size_on_disk_bytes/1048576,
    TotalReadMB  = vfs.num_of_bytes_read/1048576,
    TotalWriteMB = vfs.num_of_bytes_written/1048576
FROM sys.dm_io_virtual_file_stats(NULL,NULL) vfs
JOIN sys.master_files mf ON mf.database_id=vfs.database_id AND mf.file_id=vfs.file_id
ORDER BY CASE WHEN vfs.num_of_reads =0 THEN 0 ELSE 1.0*vfs.io_stall_read_ms /vfs.num_of_reads  END
       + CASE WHEN vfs.num_of_writes=0 THEN 0 ELSE 1.0*vfs.io_stall_write_ms/vfs.num_of_writes END DESC;
"@

# Autogrowth events from the default trace (best-effort; empty set if trace off).
$Q_AUTOGROWTH = @"
BEGIN TRY
    DECLARE @tp nvarchar(260) = (SELECT path FROM sys.traces WHERE is_default = 1);
    IF @tp IS NULL RAISERROR('no default trace', 11, 1);
    SELECT EventTime    = CAST(StartTime AS datetime2(0)),
           DatabaseName = DatabaseName,
           FileType     = CASE EventClass WHEN 92 THEN 'ROWS' WHEN 93 THEN 'LOG' ELSE '?' END,
           GrowthMB     = CAST(IntegerData * 8 / 1024.0 AS decimal(10,1)),
           DurationMs   = Duration / 1000
    FROM sys.fn_trace_gettable(@tp, DEFAULT)
    WHERE EventClass IN (92,93) AND StartTime > DATEADD(HOUR,-24,GETDATE());
END TRY
BEGIN CATCH
    SELECT CAST(NULL AS datetime2(0)) EventTime, CAST(NULL AS nvarchar(128)) DatabaseName,
           CAST(NULL AS varchar(20)) FileType, CAST(NULL AS decimal(10,1)) GrowthMB,
           CAST(NULL AS bigint) DurationMs
    WHERE 1 = 0;
END CATCH
"@

# Index health - missing indexes + never-used indexes (both cheap DMV reads).
$Q_INDEX = @"
SELECT TOP (25)
    DatabaseName = DB_NAME(mid.database_id),
    Kind         = 'missing',
    ObjectName   = mid.statement,
    IndexName    = CAST(NULL AS nvarchar(256)),
    Metric       = CONCAT('impact ', CAST(migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans) AS bigint),
                          ' · seeks ', migs.user_seeks),
    Recommendation = LEFT(CONCAT('CREATE INDEX IX_ ON ', mid.statement, ' (',
                          ISNULL(mid.equality_columns,''),
                          CASE WHEN mid.inequality_columns IS NOT NULL THEN ',' + mid.inequality_columns ELSE '' END, ')',
                          CASE WHEN mid.included_columns IS NOT NULL THEN ' INCLUDE (' + mid.included_columns + ')' ELSE '' END), 600)
FROM sys.dm_db_missing_index_groups mig
JOIN sys.dm_db_missing_index_group_stats migs ON migs.group_handle = mig.index_group_handle
JOIN sys.dm_db_missing_index_details  mid  ON mid.index_handle = mig.index_handle
ORDER BY migs.avg_total_user_cost * migs.avg_user_impact * (migs.user_seeks + migs.user_scans) DESC;
"@

# ---- Resolve MSSQL targets from THREE sources ----------------------------
#  1. CMS registered-server group          (Windows auth)
#  2. config cms.mssqlInstances            (string = Windows auth,
#       or { "instance": "...", "user": "...", "password": "..." } = SQL auth)
#  3. cfg.Servers rows added via the dashboard "Servers" tab (Windows auth)
$targets = @{}    # name -> @{ User = ...; Password = ... } (empty = integrated)
if ($cfg.cms.group) {
    Write-Host "Reading CMS group '$($cfg.cms.group)' from $($cfg.cms.cmsInstance)..." -ForegroundColor Cyan
    foreach ($n in (Get-CmsRegisteredServers -CmsInstance $cfg.cms.cmsInstance -Group $cfg.cms.group)) {
        $targets[[string]$n] = @{}
    }
}
foreach ($e in @($cfg.cms.mssqlInstances)) {
    if ($null -eq $e) { continue }
    if ($e -is [string]) { $targets[$e] = @{} }
    else {
        $pwd = if ($e.passwordEnvVar -and (Get-Item "env:$($e.passwordEnvVar)" -ErrorAction SilentlyContinue)) {
                   (Get-Item "env:$($e.passwordEnvVar)").Value
               } else { $e.password }
        $targets[[string]$e.instance] = @{ User = $e.user; Password = $pwd }
    }
}
try {
    $uiSrv = Invoke-SqlQuery -ConnString $centralConn -Query `
        "SELECT ServerName, AuthType, UserName, PasswordEnc FROM cfg.Servers WHERE IsActive = 1 AND Platform = 'MSSQL';"
    foreach ($r in $uiSrv.Rows) {
        $n = [string]$r['ServerName']
        if ($targets.ContainsKey($n)) { continue }
        if ([string]$r['AuthType'] -eq 'sql' -and $r['UserName'] -isnot [DBNull]) {
            # SQL login saved via the dashboard form; DPAPI-decrypt on this box
            $blob = if ($r['PasswordEnc'] -is [DBNull]) { $null } else { [byte[]]$r['PasswordEnc'] }
            $targets[$n] = @{ User = [string]$r['UserName']; Password = (Unprotect-DbaDashSecret $blob) }
        } else { $targets[$n] = @{} }
    }
} catch { Write-Warning "could not read cfg.Servers: $($_.Exception.Message)" }
Write-Host "MSSQL targets: $($targets.Keys -join ', ')" -ForegroundColor Gray

# ---- Fan out ----
foreach ($inst in @($targets.Keys)) {
    $now  = [datetime]::UtcNow
    $cred = $targets[$inst]
    $conn = Get-SqlConnString -Instance $inst -Database 'master' -User $cred.User -Password $cred.Password
    try {
        Register-Server -CentralConn $centralConn -ServerName $inst -Platform 'MSSQL'
        $ag  = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_AGSYNC) -ServerName $inst -CollectedAt $now
        $n1  = Write-BulkTable -ConnString $centralConn -Table $ag -Destination 'mon.AGSyncStatus'

        $dsk = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_DISK) -ServerName $inst -Platform 'MSSQL' -CollectedAt $now
        $n2  = Write-BulkTable -ConnString $centralConn -Table $dsk -Destination 'mon.DiskUsage'

        $lag = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_LAG) -ServerName $inst -Platform 'MSSQL' -CollectedAt $now
        $n3  = Write-BulkTable -ConnString $centralConn -Table $lag -Destination 'mon.DataLag'

        $siz = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_DBSIZE) -ServerName $inst -Platform 'MSSQL' -CollectedAt $now
        $n4  = Write-BulkTable -ConnString $centralConn -Table $siz -Destination 'mon.ObjectSize'

        $bak = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_BACKUP) -ServerName $inst -CollectedAt $now
        $n5  = Write-BulkTable -ConnString $centralConn -Table $bak -Destination 'mon.BackupStatus'

        $job = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_JOBS) -ServerName $inst -CollectedAt $now
        $n6  = Write-BulkTable -ConnString $centralConn -Table $job -Destination 'mon.JobFailure'

        $vit = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_VITALS) -ServerName $inst -Platform 'MSSQL' -CollectedAt $now
        $n7  = Write-BulkTable -ConnString $centralConn -Table $vit -Destination 'mon.HealthMetric'

        $act = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_ACTIVITY) -ServerName $inst -Platform 'MSSQL' -CollectedAt $now
        $n8  = Write-BulkTable -ConnString $centralConn -Table $act -Destination 'mon.QuerySnapshot'

        $wt  = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_WAITS) -ServerName $inst -CollectedAt $now
        $n9  = Write-BulkTable -ConnString $centralConn -Table $wt -Destination 'mon.WaitStats'

        $tq  = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_TOPQ) -ServerName $inst -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $tq -Destination 'mon.TopQueries')

        $fl  = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_FAILEDLOGIN) -ServerName $inst -Platform 'MSSQL' -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $fl -Destination 'mon.FailedLogin')

        $la  = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_LOGINACT) -ServerName $inst -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $la -Destination 'mon.LoginActivity')

        # server audit: patch/build, config drift, access control, index health
        $sinfo = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_SERVERINFO) -ServerName $inst -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $sinfo -Destination 'mon.ServerInfo')

        $ccfg = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_CONFIG) -ServerName $inst -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $ccfg -Destination 'mon.ConfigAudit')

        $prin = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_PRINCIPALS) -ServerName $inst -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $prin -Destination 'mon.SecurityPrincipal')

        $idx = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_INDEX) -ServerName $inst -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $idx -Destination 'mon.IndexHealth')

        # performance bottlenecks: file I/O latency + autogrowth events
        $fio = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_FILEIO) -ServerName $inst -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $fio -Destination 'mon.FileIOStats')

        $agr = Add-Envelope (Invoke-SqlQuery -ConnString $conn -Query $Q_AUTOGROWTH) -ServerName $inst -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $agr -Destination 'mon.AutoGrowth')

        Write-CollectionLog -CentralConn $centralConn -Collector 'MSSQL' -ServerName $inst -Status 'OK' `
            -RowsLoaded ($n1+$n2+$n3+$n4+$n5+$n6+$n7+$n8+$n9) `
            -Message "AG=$n1 Disk=$n2 Lag=$n3 Size=$n4 Bak=$n5 Job=$n6 Vit=$n7 Act=$n8 Wait=$n9"
        Write-Host ("  {0,-24} OK  (AG={1} Disk={2} Lag={3} Size={4} Bak={5} Job={6} Act={7})" -f $inst,$n1,$n2,$n3,$n4,$n5,$n6,$n8) -ForegroundColor Green
    } catch {
        Write-CollectionLog -CentralConn $centralConn -Collector 'MSSQL' -ServerName $inst -Status 'ERROR' -Message $_.Exception.Message
        Write-Warning ("  {0,-24} ERROR: {1}" -f $inst, $_.Exception.Message)
    }
}

# ---- Redshift ----
if ($cfg.redshift) {
    Write-Host "Collecting Redshift..." -ForegroundColor Cyan
    & "$PSScriptRoot\Collect-Redshift.ps1" -ConfigPath $ConfigPath
}

# ---- Post-process: forecast, cost anomaly, findings, alert evaluation, purge ----
# NOTE: Generate_Findings must run BEFORE Evaluate_Alerts so CRIT findings are
# available for the alert set to pick up (and dedup/auto-resolve) this cycle.
Write-Host "Refreshing forecast, detecting cost anomalies, generating findings, evaluating alerts..." -ForegroundColor Cyan
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query "EXEC cfg.usp_Refresh_DiskForecast;")
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query "EXEC cfg.usp_Detect_CostAnomaly;")
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query "EXEC cfg.usp_Generate_Findings;")
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query "EXEC cfg.usp_Evaluate_Alerts;")

# ---- Alerting (optional) ----
if ($cfg.alerting -and $cfg.alerting.enabled) {
    Write-Host "Sending alert notifications..." -ForegroundColor Cyan
    & "$PSScriptRoot\Send-Alerts.ps1" -ConfigPath $ConfigPath
}

$ret = if ($cfg.retentionDays) { [int]$cfg.retentionDays } else { 90 }
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query "EXEC cfg.usp_Purge_History @RetentionDays=$ret;")

Write-Host "Collection run complete." -ForegroundColor Green
