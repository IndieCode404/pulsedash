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
       LastGoodCheckDb=CONVERT(datetime2(0), DATABASEPROPERTYEX(d.name,'LastGoodCheckDbTime'))
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b ON b.database_name=d.name
WHERE d.database_id <> 2                     -- skip tempdb
GROUP BY d.name, d.recovery_model_desc, d.state_desc;
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
SELECT 'uptime_hours', (SELECT CAST(DATEDIFF(HOUR, sqlserver_start_time, GETDATE()) AS float) FROM sys.dm_os_sys_info), NULL;
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
        "SELECT ServerName FROM cfg.Servers WHERE IsActive = 1 AND Platform = 'MSSQL';"
    foreach ($r in $uiSrv.Rows) {
        $n = [string]$r['ServerName']
        if (-not $targets.ContainsKey($n)) { $targets[$n] = @{} }
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

# ---- Post-process: forecast, cost anomaly, alert evaluation, purge ----
Write-Host "Refreshing forecast, detecting cost anomalies, evaluating alerts..." -ForegroundColor Cyan
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query "EXEC cfg.usp_Refresh_DiskForecast;")
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query "EXEC cfg.usp_Detect_CostAnomaly;")
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query "EXEC cfg.usp_Evaluate_Alerts;")

# ---- Alerting (optional) ----
if ($cfg.alerting -and $cfg.alerting.enabled) {
    Write-Host "Sending alert notifications..." -ForegroundColor Cyan
    & "$PSScriptRoot\Send-Alerts.ps1" -ConfigPath $ConfigPath
}

$ret = if ($cfg.retentionDays) { [int]$cfg.retentionDays } else { 90 }
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query "EXEC cfg.usp_Purge_History @RetentionDays=$ret;")

Write-Host "Collection run complete." -ForegroundColor Green
