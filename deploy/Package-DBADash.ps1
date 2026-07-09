<#
    DBADash | Package-DBADash.ps1
    ---------------------------------------------------------------------------
    Builds a RUNTIME-ONLY zip you can hand to a client box - no .git history, no
    Node demo server, no build noise. The client just unzips this one file and
    follows the setup steps; they never need the repo or git.

    What goes in: the SQL deploy scripts, the PowerShell collectors + deploy +
    dashboard server, the dashboard www\ assets, the Redshift metrics, the Agent
    job script, the config TEMPLATE, and the README.

    Usage:
      .\Package-DBADash.ps1                    # -> ..\dist\DBADash-<date>-<sha>.zip
      .\Package-DBADash.ps1 -NoDemo            # omit the demo-seed SQL
      .\Package-DBADash.ps1 -IncludeBI         # also bundle powerbi\ + ssrs\
      .\Package-DBADash.ps1 -OutDir C:\builds
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [switch]$NoDemo,       # drop the *seed*.sql scripts (no demo data option)
    [switch]$IncludeBI     # add the Power BI / SSRS templates
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

# version stamp: date + short git sha when available (packaging works without git)
$stamp = Get-Date -Format 'yyyyMMdd'
$sha = $null
try { $sha = (& git -C $root rev-parse --short HEAD 2>$null) } catch { }
$ver   = if ($sha) { "$stamp-$sha" } else { $stamp }
$stage = Join-Path $OutDir 'DBADash'
$zip   = Join-Path $OutDir "DBADash-$ver.zip"

# The exact set of files the client box needs at runtime (paths relative to root).
$include = @(
    'deploy\Common.ps1', 'deploy\Deploy-DBADash.ps1', 'deploy\Collect-All.ps1',
    'deploy\Collect-Redshift.ps1', 'deploy\Send-Alerts.ps1',
    'deploy\config\dbadash.example.json',
    'redshift\redshift_metrics.sql',
    'agent\Create-AgentJobs.sql',
    'dashboard\Start-Dashboard.ps1',
    'dashboard\www\index.html', 'dashboard\www\app.js',
    'dashboard\www\styles.css', 'dashboard\www\branding.json',
    'README.md'
)
# every numbered SQL deploy script (optionally minus the demo seeds)
$sql = Get-ChildItem (Join-Path $root 'sql') -Filter *.sql | Select-Object -Expand Name
if ($NoDemo) { $sql = $sql | Where-Object { $_ -notmatch 'seed' } }
$include += ($sql | ForEach-Object { "sql\$_" })
if ($IncludeBI) { $include += 'powerbi', 'ssrs' }

# stage a clean tree
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($rel in $include) {
    $src = Join-Path $root $rel
    if (-not (Test-Path $src)) { Write-Warning "skip (missing): $rel"; continue }
    $dst = Join-Path $stage $rel
    New-Item -ItemType Directory -Path (Split-Path $dst -Parent) -Force | Out-Null
    Copy-Item $src $dst -Recurse -Force
}
"DBADash package $ver`nBuilt $(Get-Date -Format s)`nDeploy: see README.md / DEPLOY steps" |
    Set-Content (Join-Path $stage 'VERSION.txt') -Encoding UTF8

# zip it (contents at the archive root, so it unzips straight into a tree)
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force

$size = [int]((Get-Item $zip).Length / 1KB)
Write-Host "Packaged -> $zip  ($size KB)" -ForegroundColor Green
Write-Host "Copy that one file to the client box, unzip, then follow README 'Setup'." -ForegroundColor Gray
