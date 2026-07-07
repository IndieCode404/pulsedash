<#
    DBADash | Deploy-DBADash.ps1
    Builds the DBADash central database by running the numbered SQL scripts in
    ..\sql against the central instance from your config.

    Usage:
      .\Deploy-DBADash.ps1                 # build/upgrade schema
      .\Deploy-DBADash.ps1 -WithDemoData   # also load the demo seed (07)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\config\dbadash.json",
    [switch]$WithDemoData
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

$cfg    = Get-DbaDashConfig -Path $ConfigPath
$inst   = $cfg.central.sqlInstance
$sqlDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'sql'

# Ordered list of scripts to deploy centrally. NOTE: 03_collect_mssql.sql is a
# TARGET-side collection query (run on each instance by Collect-All), NOT here.
$scripts = @(
    '01_create_database.sql',   # creates DB (connects via master)
    '02_tables.sql',
    '04_procs_forecast.sql',
    '05_views_dashboard.sql',
    '06_appowners_crud.sql',
    '08_growth.sql',
    '09_cost.sql',
    '10_alerts.sql',
    '12_health.sql',
    '14_servers_admin.sql'
)
if ($WithDemoData) { $scripts += '07_seed_demo.sql','11_seed_growth_cost.sql','13_seed_health.sql' }

Write-Host "Deploying DBADash to [$inst]..." -ForegroundColor Cyan
$conn = Get-SqlConnString -Instance $inst -Database 'master' -User $cfg.central.user -Password $cfg.central.password

foreach ($s in $scripts) {
    $path = Join-Path $sqlDir $s
    if (-not (Test-Path $path)) { Write-Warning "missing $s - skipped"; continue }
    Write-Host "  -> $s" -ForegroundColor Gray
    # Split on GO batch separators (must be on their own line) since ExecuteNonQuery
    # cannot run multi-batch scripts. This is a lightweight sqlcmd substitute.
    $sqlText = Get-Content -Raw -Path $path
    $batches = [regex]::Split($sqlText, '(?im)^\s*GO\s*$')
    foreach ($b in $batches) {
        if ($b.Trim().Length -eq 0) { continue }
        [void](Invoke-SqlNonQuery -ConnString $conn -Query $b -TimeoutSec 180)
    }
}
Write-Host "Deploy complete." -ForegroundColor Green
if ($WithDemoData) { Write-Host "Demo data loaded - open the dashboard to see it." -ForegroundColor Green }
