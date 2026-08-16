<#
    DBADash | Show-Targets.ps1   (dry run - safe)
    ---------------------------------------------------------------------------
    Answers "which servers would Collect-All actually contact?" WITHOUT
    contacting any of them and without collecting anything.

    It mirrors Collect-All's target resolution exactly (same three sources, same
    precedence), so what it prints is what the collector would do.

    Connections made:
      - the central DBADash database          (read cfg.Servers)
      - the CMS instance, ONLY if cms.group is set (read the registered list)
      - NONE of the monitored targets

    Usage:
      .\Show-Targets.ps1             # list only - writes nothing
      .\Show-Targets.ps1 -Register   # also upsert them into cfg.Servers (still no collection)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\config\dbadash.json",
    [switch]$Register
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

$cfg = Get-DbaDashConfig -Path $ConfigPath
$centralConn = Get-SqlConnString -Instance $cfg.central.sqlInstance -Database $cfg.central.database `
                                 -User $cfg.central.user -Password $cfg.central.password

Write-Host ""
Write-Host "Central DBADash : [$($cfg.central.sqlInstance)].[$($cfg.central.database)]" -ForegroundColor Cyan

# ---- MSSQL: same hashtable + precedence as Collect-All ---------------------
#      (CMS first, config mssqlInstances overwrites, cfg.Servers fills gaps)
$targets = @{}

if ($cfg.cms.group) {
    Write-Host "CMS group       : '$($cfg.cms.group)' on $($cfg.cms.cmsInstance)" -ForegroundColor Yellow
    try {
        foreach ($n in (Get-CmsRegisteredServers -CmsInstance $cfg.cms.cmsInstance -Group $cfg.cms.group)) {
            $targets[[string]$n] = @{ Source = 'CMS group'; Auth = 'Windows' }
        }
    } catch { Write-Warning "CMS read failed: $($_.Exception.Message)" }
} else {
    Write-Host "CMS group       : disabled (cms.group is null)" -ForegroundColor DarkGray
}

foreach ($e in @($cfg.cms.mssqlInstances)) {
    if ($null -eq $e) { continue }
    if ($e -is [string]) { $targets[$e] = @{ Source = 'config mssqlInstances'; Auth = 'Windows' } }
    else { $targets[[string]$e.instance] = @{ Source = 'config mssqlInstances'; Auth = "SQL login '$($e.user)'" } }
}

try {
    $uiSrv = Invoke-SqlQuery -ConnString $centralConn -Query `
        "SELECT ServerName, AuthType FROM cfg.Servers WHERE IsActive = 1 AND Platform = 'MSSQL';"
    foreach ($r in $uiSrv.Rows) {
        $n = [string]$r['ServerName']
        if ($targets.ContainsKey($n)) { continue }        # already claimed by a higher source
        $targets[$n] = @{ Source = 'cfg.Servers (registered)'
                          Auth   = $(if ([string]$r['AuthType'] -eq 'sql') { 'SQL login (DPAPI)' } else { 'Windows' }) }
    }
} catch { Write-Warning "could not read cfg.Servers: $($_.Exception.Message)" }

# ---- Redshift: same merge as Collect-Redshift (config wins on clusterId) ---
$rs = @{}
foreach ($c in @($cfg.redshift | Where-Object { $_ })) {
    $rs[[string]$c.clusterId] = @{ Source = 'config redshift'; Auth = "ODBC '$($c.user)'"; Host = [string]$c.host }
}
try {
    $uiRs = Invoke-SqlQuery -ConnString $centralConn -Query `
        "SELECT ServerName, Host FROM cfg.Servers WHERE IsActive = 1 AND Platform = 'Redshift' AND Host IS NOT NULL;"
    foreach ($r in $uiRs.Rows) {
        $n = [string]$r['ServerName']
        if ($rs.ContainsKey($n)) { continue }
        $rs[$n] = @{ Source = 'cfg.Servers (registered)'; Auth = 'ODBC (DPAPI)'; Host = [string]$r['Host'] }
    }
} catch { }

# ---- report ---------------------------------------------------------------
$out = @()
foreach ($k in ($targets.Keys | Sort-Object)) {
    $out += [pscustomobject]@{ Platform='MSSQL'; ServerName=$k; Auth=$targets[$k].Auth; Source=$targets[$k].Source }
}
foreach ($k in ($rs.Keys | Sort-Object)) {
    $out += [pscustomobject]@{ Platform='Redshift'; ServerName=$k; Auth=$rs[$k].Auth; Source=$rs[$k].Source }
}

Write-Host ""
if ($out.Count -eq 0) {
    Write-Host "NO TARGETS RESOLVED - Collect-All would connect to nothing." -ForegroundColor Yellow
    Write-Host "Add instances to cms.mssqlInstances (or a CMS group) in $ConfigPath." -ForegroundColor Gray
} else {
    Write-Host "Collect-All WOULD contact these $($out.Count) target(s):" -ForegroundColor Green
    $out | Format-Table Platform, ServerName, Auth, Source -AutoSize
}

Write-Host "No target was connected to by this script." -ForegroundColor DarkGray

# ---- optional: register them in cfg.Servers (inventory only, no collection) --
if ($Register -and $out.Count -gt 0) {
    Write-Host "Registering the above in cfg.Servers (inventory only)..." -ForegroundColor Cyan
    foreach ($o in $out) {
        Register-Server -CentralConn $centralConn -ServerName $o.ServerName -Platform $o.Platform -Environment 'PROD'
        Write-Host "  + $($o.ServerName)" -ForegroundColor Gray
    }
    Write-Host "Done. Check:  SELECT * FROM cfg.Servers;" -ForegroundColor Green
}
