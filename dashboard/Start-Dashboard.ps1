<#
    DBADash | Start-Dashboard.ps1
    ---------------------------------------------------------------------------
    A zero-dependency dashboard: a small PowerShell HTTP server that serves the
    static UI in .\www and exposes a JSON API backed by the DBADash reporting
    views + the app-owner upsert proc.

    Usage:
        .\Start-Dashboard.ps1                      # http://localhost:8080
        .\Start-Dashboard.ps1 -Port 9000
        .\Start-Dashboard.ps1 -Instance SQLMON01 -Database DBADash

    If you get "Access is denied" binding the listener, either run this shell as
    Administrator once, or reserve the URL (as admin):
        netsh http add urlacl url=http://+:8080/ user=DOMAIN\you
#>
[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string]$ConfigPath = "$PSScriptRoot\..\deploy\config\dbadash.json",
    [string]$Instance,
    [string]$Database = 'DBADash',
    [string]$User = '',
    [string]$Password = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data | Out-Null

# Resolve connection: explicit -Instance wins, else read the collector config.
if (-not $Instance -and (Test-Path $ConfigPath)) {
    $cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
    $Instance = $cfg.central.sqlInstance; $Database = $cfg.central.database
    $User = $cfg.central.user; $Password = $cfg.central.password
}
if (-not $Instance) { throw "No SQL instance. Pass -Instance or create deploy\config\dbadash.json." }

$connString = "Server=$Instance;Database=$Database;TrustServerCertificate=True;Application Name=DBADash-UI;"
$connString += if ([string]::IsNullOrWhiteSpace($User)) { "Integrated Security=SSPI;" } else { "User ID=$User;Password=$Password;" }

# ---- data helpers ----------------------------------------------------------
function Query-Json([string]$sql) {
    $c = New-Object System.Data.SqlClient.SqlConnection $connString
    try {
        $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = $sql
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable; [void]$da.Fill($dt)
        $rows = foreach ($r in $dt.Rows) {
            $o = [ordered]@{}
            foreach ($col in $dt.Columns) {
                $v = $r[$col.ColumnName]
                $o[$col.ColumnName] = if ($v -is [DBNull]) { $null } else { $v }
            }
            $o
        }
        return ,@($rows)
    } finally { $c.Dispose() }
}

function Query-Growth([string]$platform, [string]$server, [string]$object) {
    $c = New-Object System.Data.SqlClient.SqlConnection $connString
    try {
        $c.Open(); $cmd = $c.CreateCommand()
        $cmd.CommandText = 'SELECT Day, SizeGB FROM rpt.GrowthDaily
            WHERE Platform=@p AND ServerName=@s AND ObjectName=@o ORDER BY Day;'
        [void]$cmd.Parameters.AddWithValue('@p', $platform)
        [void]$cmd.Parameters.AddWithValue('@s', $server)
        [void]$cmd.Parameters.AddWithValue('@o', $object)
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable; [void]$da.Fill($dt)
        $rows = foreach ($r in $dt.Rows) { [ordered]@{ Day = $r['Day'].ToString('yyyy-MM-dd'); SizeGB = $r['SizeGB'] } }
        return ,@($rows)
    } finally { $c.Dispose() }
}

function Query-CostTrend([string]$server, [string]$metric) {
    $c = New-Object System.Data.SqlClient.SqlConnection $connString
    try {
        $c.Open(); $cmd = $c.CreateCommand()
        $cmd.CommandText = 'SELECT Day, Value, MetricUnit FROM rpt.CostTrend
            WHERE ServerName=@s AND MetricName=@m ORDER BY Day;'
        [void]$cmd.Parameters.AddWithValue('@s', $server)
        [void]$cmd.Parameters.AddWithValue('@m', $metric)
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable; [void]$da.Fill($dt)
        $rows = foreach ($r in $dt.Rows) {
            [ordered]@{ Day = $r['Day'].ToString('yyyy-MM-dd'); Value = $r['Value']
                        MetricUnit = if ($r['MetricUnit'] -is [DBNull]) { '' } else { $r['MetricUnit'] } }
        }
        return ,@($rows)
    } finally { $c.Dispose() }
}

function Upsert-Owner($body) {
    $c = New-Object System.Data.SqlClient.SqlConnection $connString
    try {
        $c.Open(); $cmd = $c.CreateCommand()
        $cmd.CommandText = 'cfg.usp_AppOwner_Upsert'
        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
        [void]$cmd.Parameters.AddWithValue('@AppOwnerID', [int]($body.AppOwnerID | ForEach-Object { if ($_) {$_} else {0} }))
        [void]$cmd.Parameters.AddWithValue('@ServerName', [string]$body.ServerName)
        [void]$cmd.Parameters.AddWithValue('@DatabaseName', $(if($body.DatabaseName){$body.DatabaseName}else{'(instance)'}))
        [void]$cmd.Parameters.AddWithValue('@AppName', [string]$body.AppName)
        [void]$cmd.Parameters.AddWithValue('@Criticality', $(if($body.Criticality){$body.Criticality}else{'Tier3'}))
        foreach ($p in 'PrimaryOwner','SecondaryOwner','Team','Email','OnCallPhone','Notes') {
            $val = $body.$p; [void]$cmd.Parameters.AddWithValue("@$p", $(if([string]::IsNullOrEmpty([string]$val)){[DBNull]::Value}else{$val}))
        }
        [void]$cmd.ExecuteNonQuery()
    } finally { $c.Dispose() }
}

function Upsert-Server($body) {
    $c = New-Object System.Data.SqlClient.SqlConnection $connString
    try {
        $c.Open(); $cmd = $c.CreateCommand()
        $cmd.CommandText = 'cfg.usp_Server_Upsert'
        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
        [void]$cmd.Parameters.AddWithValue('@ServerName', [string]$body.ServerName)
        [void]$cmd.Parameters.AddWithValue('@Platform', $(if($body.Platform){$body.Platform}else{'MSSQL'}))
        [void]$cmd.Parameters.AddWithValue('@Environment', $(if($body.Environment){$body.Environment}else{'PROD'}))
        $fn = if ([string]::IsNullOrEmpty([string]$body.FriendlyName)) { [DBNull]::Value } else { $body.FriendlyName }
        [void]$cmd.Parameters.AddWithValue('@FriendlyName', $fn)
        [void]$cmd.Parameters.AddWithValue('@IsActive', $(if($null -ne $body.IsActive -and -not $body.IsActive){0}else{1}))
        [void]$cmd.ExecuteNonQuery()
    } finally { $c.Dispose() }
}

function Delete-Server([int]$id) {
    $c = New-Object System.Data.SqlClient.SqlConnection $connString
    try {
        $c.Open(); $cmd = $c.CreateCommand()
        $cmd.CommandText = 'cfg.usp_Server_Delete'; $cmd.CommandType = 'StoredProcedure'
        [void]$cmd.Parameters.AddWithValue('@ServerID', $id)
        [void]$cmd.ExecuteNonQuery()
    } finally { $c.Dispose() }
}

function Delete-Owner([int]$id) {
    $c = New-Object System.Data.SqlClient.SqlConnection $connString
    try {
        $c.Open(); $cmd = $c.CreateCommand()
        $cmd.CommandText = "cfg.usp_AppOwner_Delete"; $cmd.CommandType = 'StoredProcedure'
        [void]$cmd.Parameters.AddWithValue('@AppOwnerID', $id)
        [void]$cmd.ExecuteNonQuery()
    } finally { $c.Dispose() }
}

# ---- tiny HTTP server ------------------------------------------------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "DBADash dashboard running:  http://localhost:$Port/   (Ctrl+C to stop)" -ForegroundColor Green
Write-Host "  data source: [$Instance].[$Database]" -ForegroundColor Gray

$www   = Join-Path $PSScriptRoot 'www'
$types = @{ '.html'='text/html'; '.css'='text/css'; '.js'='application/javascript'; '.svg'='image/svg+xml' }

function Send-Json($ctx, $obj, [int]$code = 200) {
    $json  = $obj | ConvertTo-Json -Depth 6 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.OutputStream.Close()
}

try {
    while ($listener.IsListening) {
        $ctx  = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath.TrimEnd('/')
        $verb = $ctx.Request.HttpMethod
        try {
            switch -Regex ("$verb $path") {
                '^GET /api/overview$' { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.Overview;') ; break }
                '^GET /api/ag$'       { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.AGSyncStatus ORDER BY Status DESC, AGName, DatabaseName;') ; break }
                '^GET /api/lag$'      { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.DataLag ORDER BY CASE Status WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, LagSeconds DESC;') ; break }
                '^GET /api/disk$'     { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.DiskForecast ORDER BY CASE Severity WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, DaysToFull;') ; break }
                '^GET /api/owners$'   { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.AppOwners ORDER BY Criticality, ServerName, AppName;') ; break }
                '^GET /api/growthkeys$' { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.GrowthKeys ORDER BY GrowthGBPerDay DESC;') ; break }
                '^GET /api/growth$'   {
                    $qs = $ctx.Request.QueryString
                    Send-Json $ctx (Query-Growth $qs['platform'] $qs['server'] $qs['object']) ; break
                }
                '^GET /api/cost$'     { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.CostAnomaly;') ; break }
                '^GET /api/costkeys$' { Send-Json $ctx (Query-Json 'SELECT DISTINCT ServerName, MetricName, MetricUnit FROM rpt.CostTrend ORDER BY ServerName, MetricName;') ; break }
                '^GET /api/costtrend$' {
                    $qs = $ctx.Request.QueryString
                    Send-Json $ctx (Query-CostTrend $qs['server'] $qs['metric']) ; break
                }
                '^GET /api/alerts$'   { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.ActiveAlerts ORDER BY CASE Severity WHEN ''CRIT'' THEN 0 ELSE 1 END, LastSeen DESC;') ; break }
                '^GET /api/backups$'  { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.BackupHealth ORDER BY CASE Status WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, ServerName, DatabaseName;') ; break }
                '^GET /api/jobs$'     { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.JobFailures ORDER BY RunAt DESC;') ; break }
                '^GET /api/vitals$'   { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.InstanceVitals ORDER BY CASE Status WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, ServerName, MetricName;') ; break }
                '^GET /api/activity$' { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.ActiveQueries ORDER BY CASE RowStatus WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, DurationSec DESC;') ; break }
                '^GET /api/waits$'    { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.TopWaits ORDER BY ServerName, WaitTimeMs DESC;') ; break }
                '^GET /api/tablehealth$' { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.TableHealth ORDER BY CASE Status WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, UnsortedPct DESC;') ; break }
                '^GET /api/servers$'  { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.Servers ORDER BY IsActive DESC, Platform, ServerName;') ; break }
                '^POST /api/servers/delete$' {
                    $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd() | ConvertFrom-Json
                    Delete-Server ([int]$body.ServerID); Send-Json $ctx @{ ok = $true }; break
                }
                '^POST /api/servers$' {
                    $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd() | ConvertFrom-Json
                    Upsert-Server $body; Send-Json $ctx @{ ok = $true }; break
                }
                '^POST /api/owners/delete$' {
                    $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd() | ConvertFrom-Json
                    Delete-Owner ([int]$body.AppOwnerID); Send-Json $ctx @{ ok = $true }; break
                }
                '^POST /api/owners$' {
                    $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd() | ConvertFrom-Json
                    Upsert-Owner $body; Send-Json $ctx @{ ok = $true }; break
                }
                default {
                    # static file
                    $rel = if ($path -eq '') { 'index.html' } else { $path.TrimStart('/') }
                    $file = Join-Path $www $rel
                    if (Test-Path $file) {
                        $ext = [IO.Path]::GetExtension($file)
                        $ct  = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
                        $bytes = [IO.File]::ReadAllBytes($file)
                        $ctx.Response.ContentType = $ct
                        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $ctx.Response.OutputStream.Close()
                    } else {
                        $ctx.Response.StatusCode = 404; $ctx.Response.Close()
                    }
                }
            }
        } catch {
            Send-Json $ctx @{ error = $_.Exception.Message } 500
        }
    }
} finally { $listener.Stop() }
