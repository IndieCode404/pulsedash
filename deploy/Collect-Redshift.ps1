<#
    DBADash | Collect-Redshift.ps1
    ---------------------------------------------------------------------------
    Queries each Redshift cluster in config via ODBC and loads:
       - cluster disk usage -> mon.DiskUsage  (Platform='Redshift')
       - table load lag      -> mon.DataLag    (Platform='Redshift', load_freshness)

    Requirements: an ODBC driver for Redshift. Either
      (a) "Amazon Redshift ODBC Driver (x64)"  (recommended), or
      (b) "PostgreSQL Unicode(x64)"            (Redshift speaks the PG wire protocol), or
      (c) a preconfigured System DSN (set "dsn" in config to use it).

    Password precedence: env var DBADASH_RS_PWD  >  config "password".
#>
[CmdletBinding()]
param([string]$ConfigPath = "$PSScriptRoot\config\dbadash.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

$cfg         = Get-DbaDashConfig -Path $ConfigPath
$centralConn = Get-SqlConnString -Instance $cfg.central.sqlInstance -Database $cfg.central.database `
                                 -User $cfg.central.user -Password $cfg.central.password
$metricsFile = Join-Path (Split-Path $PSScriptRoot -Parent) 'redshift\redshift_metrics.sql'

$qDisk  = Get-SqlBlock -Path $metricsFile -Name 'DISK'
$qFresh = Get-SqlBlock -Path $metricsFile -Name 'FRESHNESS'
$qSize  = Get-SqlBlock -Path $metricsFile -Name 'TABLE_SIZE'
$qCost  = Get-SqlBlock -Path $metricsFile -Name 'COST'
$qThl   = Get-SqlBlock -Path $metricsFile -Name 'TABLE_HEALTH'
$qAct   = Get-SqlBlock -Path $metricsFile -Name 'ACTIVITY'
$qVit   = Get-SqlBlock -Path $metricsFile -Name 'RS_VITALS'
$qScan  = Get-SqlBlock -Path $metricsFile -Name 'TABLE_SCAN'
$qSpec  = Get-SqlBlock -Path $metricsFile -Name 'SPECTRUM'
$qLogin = Get-SqlBlock -Path $metricsFile -Name 'RS_LOGINS'

function Get-RedshiftOdbcConnString($rs) {
    if ($rs.dsn) { return "DSN=$($rs.dsn);" }
    $pwd = if ($env:DBADASH_RS_PWD) { $env:DBADASH_RS_PWD } else { $rs.password }
    # Prefer the Amazon driver; fall back to the PostgreSQL Unicode driver if the
    # first isn't installed. Both accept this host/port/database/uid/pwd shape.
    $drivers = @('Amazon Redshift ODBC Driver (x64)', 'PostgreSQL Unicode(x64)')
    $installed = (Get-OdbcDriver -ErrorAction SilentlyContinue | Select-Object -Expand Name)
    $driver = ($drivers | Where-Object { $installed -contains $_ } | Select-Object -First 1)
    if (-not $driver) { $driver = $drivers[0] }   # try anyway; error will be logged
    return "Driver={$driver};Server=$($rs.host);Port=$($rs.port);Database=$($rs.database);Uid=$($rs.user);Pwd=$pwd;SSLMode=require;"
}

# Merge cluster list: config file + clusters saved via the dashboard "Servers"
# form (Platform=Redshift with a Host). Config wins on clusterId collisions.
$clusters = @() + @($cfg.redshift | Where-Object { $_ })
try {
    $uiRs = Invoke-SqlQuery -ConnString $centralConn -Query `
        "SELECT ServerName, Host, Port, DatabaseName, UserName, PasswordEnc
         FROM cfg.Servers WHERE IsActive = 1 AND Platform = 'Redshift' AND Host IS NOT NULL;"
    foreach ($r in $uiRs.Rows) {
        $id = [string]$r['ServerName']
        if ($clusters | Where-Object { $_.clusterId -eq $id }) { continue }
        $blob = if ($r['PasswordEnc'] -is [DBNull]) { $null } else { [byte[]]$r['PasswordEnc'] }
        $clusters += [pscustomobject]@{
            clusterId = $id; environment = 'PROD'
            host = [string]$r['Host']; port = [int]$r['Port']
            database = [string]$r['DatabaseName']; user = [string]$r['UserName']
            password = (Unprotect-DbaDashSecret $blob); dsn = ''
        }
    }
} catch { Write-Warning "could not read cfg.Servers Redshift rows: $($_.Exception.Message)" }

foreach ($rs in $clusters) {
    $now  = [datetime]::UtcNow
    $conn = Get-RedshiftOdbcConnString $rs
    try {
        Register-Server -CentralConn $centralConn -ServerName $rs.clusterId -Platform 'Redshift' `
                        -Environment $rs.environment -FriendlyName $rs.clusterId

        $disk = Add-Envelope (Invoke-OdbcQuery -ConnString $conn -Query $qDisk) `
                    -ServerName $rs.clusterId -Platform 'Redshift' -CollectedAt $now
        $n1 = Write-BulkTable -ConnString $centralConn -Table $disk -Destination 'mon.DiskUsage'

        $fresh = Invoke-OdbcQuery -ConnString $conn -Query $qFresh
        # Freshness query returns ObjectName, LagSeconds - add Metric + envelope.
        if (-not $fresh.Columns.Contains('Metric')) { [void]$fresh.Columns.Add('Metric',[string]) }
        if (-not $fresh.Columns.Contains('Detail')) { [void]$fresh.Columns.Add('Detail',[string]) }
        foreach ($r in $fresh.Rows) { $r['Metric'] = 'load_freshness' }
        $fresh = Add-Envelope $fresh -ServerName $rs.clusterId -Platform 'Redshift' -CollectedAt $now
        $n2 = Write-BulkTable -ConnString $centralConn -Table $fresh -Destination 'mon.DataLag'

        # table sizes -> growth chart
        $size = Invoke-OdbcQuery -ConnString $conn -Query $qSize
        if (-not $size.Columns.Contains('ObjectType')) { [void]$size.Columns.Add('ObjectType',[string]) }
        foreach ($r in $size.Rows) { $r['ObjectType'] = 'table' }
        $size = Add-Envelope $size -ServerName $rs.clusterId -Platform 'Redshift' -CollectedAt $now
        $n3 = Write-BulkTable -ConnString $centralConn -Table $size -Destination 'mon.ObjectSize'

        # cost drivers -> anomaly detection (ServerName only, no Platform column)
        $cost = Invoke-OdbcQuery -ConnString $conn -Query $qCost
        $cost = Add-Envelope $cost -ServerName $rs.clusterId -CollectedAt $now
        $n4 = Write-BulkTable -ConnString $centralConn -Table $cost -Destination 'mon.RedshiftCost'

        # table health (vacuum/analyze debt)
        $thl = Add-Envelope (Invoke-OdbcQuery -ConnString $conn -Query $qThl) -ServerName $rs.clusterId -CollectedAt $now
        $n5  = Write-BulkTable -ConnString $centralConn -Table $thl -Destination 'mon.TableHealth'

        # long-running queries
        $act = Add-Envelope (Invoke-OdbcQuery -ConnString $conn -Query $qAct) -ServerName $rs.clusterId -Platform 'Redshift' -CollectedAt $now
        $n6  = Write-BulkTable -ConnString $centralConn -Table $act -Destination 'mon.QuerySnapshot'

        # cluster vitals (queued queries, connections, load errors)
        $vit = Add-Envelope (Invoke-OdbcQuery -ConnString $conn -Query $qVit) -ServerName $rs.clusterId -Platform 'Redshift' -CollectedAt $now
        $n7  = Write-BulkTable -ConnString $centralConn -Table $vit -Destination 'mon.HealthMetric'

        # last-scan times (stale-data detection), Spectrum by table, failed logins
        $scn = Add-Envelope (Invoke-OdbcQuery -ConnString $conn -Query $qScan) -ServerName $rs.clusterId -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $scn -Destination 'mon.TableScan')
        $spc = Add-Envelope (Invoke-OdbcQuery -ConnString $conn -Query $qSpec) -ServerName $rs.clusterId -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $spc -Destination 'mon.SpectrumScan')
        $flg = Add-Envelope (Invoke-OdbcQuery -ConnString $conn -Query $qLogin) -ServerName $rs.clusterId -Platform 'Redshift' -CollectedAt $now
        [void](Write-BulkTable -ConnString $centralConn -Table $flg -Destination 'mon.FailedLogin')

        Write-CollectionLog -CentralConn $centralConn -Collector 'Redshift' -ServerName $rs.clusterId `
            -Status 'OK' -RowsLoaded ($n1+$n2+$n3+$n4+$n5+$n6+$n7) `
            -Message "Disk=$n1 Freshness=$n2 Size=$n3 Cost=$n4 TblHealth=$n5 Act=$n6 Vit=$n7"
        Write-Host ("  {0,-24} OK  (Disk={1} Fresh={2} Size={3} Cost={4} Health={5})" -f $rs.clusterId,$n1,$n2,$n3,$n4,$n5) -ForegroundColor Green
    } catch {
        Write-CollectionLog -CentralConn $centralConn -Collector 'Redshift' -ServerName $rs.clusterId `
            -Status 'ERROR' -Message $_.Exception.Message
        Write-Warning ("  {0,-24} ERROR: {1}" -f $rs.clusterId, $_.Exception.Message)
    }
}
