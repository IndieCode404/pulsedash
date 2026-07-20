<#
    DBADash | Deploy-DBADash.ps1
    Builds the DBADash central database by running the numbered SQL scripts in
    ..\sql against the central instance.

    First run is interactive: if it doesn't already know the instance / login, it
    ASKS for them, then saves them to deploy\config\dbadash.json so the collector
    and dashboard reuse the same connection. Nothing is asked if the config (or
    the -Instance / -User / -Password parameters) already supply it.

    Usage:
      .\Deploy-DBADash.ps1                       # prompts on first run
      .\Deploy-DBADash.ps1 -Instance SQLMON01    # Windows auth, no prompts
      .\Deploy-DBADash.ps1 -Instance SQLMON01 -User dbadash -Password ****
      .\Deploy-DBADash.ps1 -WithDemoData         # also load the demo seed
      .\Deploy-DBADash.ps1 -NonInteractive       # never prompt (fail instead)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\config\dbadash.json",
    [string]$Instance,
    [string]$User,
    [string]$Password,
    [switch]$WithDemoData,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

# --- load the config, scaffolding it from the template on a fresh box ---------
if (-not (Test-Path $ConfigPath)) {
    $example = Join-Path (Split-Path $ConfigPath -Parent) 'dbadash.example.json'
    if (-not (Test-Path $example)) { throw "No config and no template at $example" }
    Copy-Item $example $ConfigPath
    Write-Host "Created $ConfigPath from the template." -ForegroundColor Gray
}
$cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
if (-not $cfg.central) {
    $cfg | Add-Member -NotePropertyName central -NotePropertyValue ([pscustomobject]@{
        sqlInstance = ''; database = 'DBADash'; user = ''; password = '' }) -Force
}

# --- resolve the instance:  -Instance  >  config  >  ASK -----------------------
if (-not $Instance) { $Instance = [string]$cfg.central.sqlInstance }
if (-not $Instance) {
    if ($NonInteractive) { throw "No instance. Pass -Instance or set central.sqlInstance in the config." }
    $Instance = Read-Host "SQL Server instance where the DBADash database will be created (e.g. SQLMON01 or HOST\SQLEXPRESS)"
}
if ([string]::IsNullOrWhiteSpace($Instance)) { throw "An instance name is required." }

# --- resolve authentication:  params  >  config  >  ASK (Windows or SQL) -------
$authUser = if ($PSBoundParameters.ContainsKey('User'))     { $User }     else { [string]$cfg.central.user }
$authPwd  = if ($PSBoundParameters.ContainsKey('Password')) { $Password } else { [string]$cfg.central.password }

$askAuth = -not $PSBoundParameters.ContainsKey('User') -and [string]::IsNullOrEmpty($authUser)
if ($askAuth -and -not $NonInteractive) {
    $mode = Read-Host "Authentication - [W]indows (recommended) or [S]QL login?  (W/S, default W)"
    if ($mode -match '^\s*[Ss]') {
        $authUser = Read-Host "SQL login name"
        $sec      = Read-Host "Password for '$authUser'" -AsSecureString
        $authPwd  = [System.Net.NetworkCredential]::new('', $sec).Password
    } else {
        $authUser = ''; $authPwd = ''   # Windows / integrated auth
    }
}

# --- pre-flight: fail fast with a friendly message if we can't connect ---------
$conn = Get-SqlConnString -Instance $Instance -Database 'master' -User $authUser -Password $authPwd
Write-Host "Connecting to [$Instance] as $(if ($authUser) { "SQL login '$authUser'" } else { 'the current Windows account' })..." -ForegroundColor Cyan
try {
    $probe = New-Object System.Data.SqlClient.SqlConnection $conn
    try { $probe.Open() } finally { $probe.Dispose() }
} catch {
    throw "Could not connect to [$Instance]: $($_.Exception.GetBaseException().Message)`n" +
          "Check the instance name, that SQL Server is reachable, and that this login can CREATE DATABASE."
}

# --- run the numbered deploy scripts (target-side collection lives in the collector) ---
$sqlDir  = Join-Path (Split-Path $PSScriptRoot -Parent) 'sql'
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
    '14_servers_admin.sql',
    '15_perf_audit_cost.sql',
    '16_connections.sql',
    '17_advisor.sql',
    '18_server_audit.sql',
    '19_bottlenecks.sql',
    '20_query_cost.sql',
    '21_estate.sql'
)
if ($WithDemoData) { $scripts += '07_seed_demo.sql','11_seed_growth_cost.sql','13_seed_health.sql' }

Write-Host "Deploying DBADash to [$Instance]..." -ForegroundColor Cyan
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

# --- persist what we resolved so the collector + dashboard reuse it ------------
$cfg.central.sqlInstance = $Instance
if ([string]::IsNullOrEmpty([string]$cfg.central.database)) { $cfg.central.database = 'DBADash' }
$cfg.central.user     = [string]$authUser
$cfg.central.password = [string]$authPwd
$cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding UTF8

Write-Host "Deploy complete. Central settings saved to $ConfigPath." -ForegroundColor Green
if ($authPwd) {
    Write-Host "NOTE: a SQL password is now stored (plaintext) in that config file - it is" -ForegroundColor Yellow
    Write-Host "      git-ignored and protected only by NTFS. Prefer Windows auth where you can," -ForegroundColor Yellow
    Write-Host "      and make sure the SQL Agent job runs as an account that can reach [$Instance]." -ForegroundColor Yellow
}
if ($WithDemoData) { Write-Host "Demo data loaded - open the dashboard to see it." -ForegroundColor Green }
