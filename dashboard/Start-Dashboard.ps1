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
. "$PSScriptRoot\..\deploy\Common.ps1"   # DPAPI secret helpers + Get-SqlConnString

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
        foreach ($p in @{ '@Host'=$body.Host; '@DatabaseName'=$body.DatabaseName; '@UserName'=$body.UserName }.GetEnumerator()) {
            $v = if ([string]::IsNullOrEmpty([string]$p.Value)) { [DBNull]::Value } else { [string]$p.Value }
            [void]$cmd.Parameters.AddWithValue($p.Key, $v)
        }
        [void]$cmd.Parameters.AddWithValue('@Port', $(if($body.Port){[int]$body.Port}else{[DBNull]::Value}))
        [void]$cmd.Parameters.AddWithValue('@AuthType', $(if($body.AuthType -eq 'sql'){'sql'}else{'windows'}))
        # Encrypt with DPAPI before it ever leaves this process. Blank = keep stored.
        $pe = $cmd.Parameters.Add('@PasswordEnc', [System.Data.SqlDbType]::VarBinary, -1)
        $blob = Protect-DbaDashSecret ([string]$body.Password)
        $pe.Value = if ($blob) { $blob } else { [DBNull]::Value }
        [void]$cmd.ExecuteNonQuery()
    } finally { $c.Dispose() }
}

# DBeaver-style "Test Connection": try to reach the target with the form's
# settings and report success or the driver's error message.
function Test-ServerConnection($body) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($body.Platform -eq 'Redshift') {
            # OdbcConnectionStringBuilder safely quotes host/uid/pwd (no injection).
            $b = New-Object System.Data.Odbc.OdbcConnectionStringBuilder
            $b.Driver      = 'Amazon Redshift ODBC Driver (x64)'
            $b['Server']   = [string]$body.Host
            $b['Port']     = [string]$body.Port
            $b['Database'] = [string]$body.DatabaseName
            $b['Uid']      = [string]$body.UserName
            $b['Pwd']      = [string]$body.Password
            $b['SSLMode']  = 'require'
            $oc = New-Object System.Data.Odbc.OdbcConnection $b.ConnectionString
            try { $oc.ConnectionTimeout = 10; $oc.Open() } finally { $oc.Dispose() }
        } else {
            $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
            $b.DataSource             = [string]$body.ServerName
            $b.InitialCatalog         = 'master'
            $b.TrustServerCertificate = $true
            $b.ConnectTimeout         = 10
            $b.ApplicationName        = 'DBADash-Test'
            if ($body.AuthType -eq 'sql') { $b.UserID = [string]$body.UserName; $b.Password = [string]$body.Password }
            else { $b.IntegratedSecurity = $true }
            $sc = New-Object System.Data.SqlClient.SqlConnection $b.ConnectionString
            try { $sc.Open() } finally { $sc.Dispose() }
        }
        return @{ ok = $true; message = "Connected in $($sw.ElapsedMilliseconds) ms" }
    } catch {
        return @{ ok = $false; message = $_.Exception.GetBaseException().Message }
    }
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
$types = @{ '.html'='text/html'; '.css'='text/css'; '.js'='application/javascript'; '.svg'='image/svg+xml'; '.json'='application/json'; '.png'='image/png'; '.jpg'='image/jpeg'; '.gif'='image/gif' }

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

        # CSRF guard: state-changing (POST) requests must carry our custom header -
        # a browser cannot set it on a cross-site "simple" request without a CORS
        # preflight, which we never approve - and must not arrive from a foreign
        # Origin. Read-only GETs are unaffected. app.js sends X-DBADash on every call.
        if ($verb -eq 'POST') {
            $origin = $ctx.Request.Headers['Origin']
            $okHdr  = -not [string]::IsNullOrEmpty($ctx.Request.Headers['X-DBADash'])
            $okOrig = [string]::IsNullOrEmpty($origin) -or
                      ($origin -match '^https?://(localhost|127\.0\.0\.1)(:\d+)?$')
            if (-not $okHdr -or -not $okOrig) {
                Send-Json $ctx @{ error = 'forbidden' } 403
                continue
            }
        }

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
                '^GET /api/topqueries$'  { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.TopQueries ORDER BY TotalCpuMs DESC;') ; break }
                '^GET /api/findings$'    { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.Findings ORDER BY CASE Severity WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, AgeMinutes DESC;') ; break }
                '^GET /api/serverinfo$'  { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.ServerInfo ORDER BY ServerName;') ; break }
                '^GET /api/configaudit$' { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.ConfigAudit ORDER BY CASE Status WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, ServerName, ConfigItem;') ; break }
                '^GET /api/accesscontrol$' { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.AccessControl ORDER BY ServerName, CASE AccessType WHEN ''Sysadmin'' THEN 0 WHEN ''Security admin'' THEN 1 WHEN ''Elevated'' THEN 2 WHEN ''Standard'' THEN 3 WHEN ''Connect-only'' THEN 4 ELSE 5 END;') ; break }
                '^GET /api/principals$'  { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.Principals ORDER BY ServerName, CASE AccessType WHEN ''Sysadmin'' THEN 0 WHEN ''Security admin'' THEN 1 WHEN ''Elevated'' THEN 2 WHEN ''Standard'' THEN 3 WHEN ''Connect-only'' THEN 4 ELSE 5 END, PrincipalName;') ; break }
                '^GET /api/indexhealth$' { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.IndexHealth ORDER BY ServerName, Kind, ObjectName;') ; break }
                '^GET /api/fileio$'      { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.FileIOStats ORDER BY CASE Status WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, (ISNULL(ReadLatencyMs,0)+ISNULL(WriteLatencyMs,0)) DESC;') ; break }
                '^GET /api/waitdelta$'   { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.WaitDelta ORDER BY ServerName, DeltaMs DESC;') ; break }
                '^GET /api/autogrowth$'  { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.AutoGrowthEvents ORDER BY EventTime DESC;') ; break }
                '^GET /api/failedlogins$'{ Send-Json $ctx (Query-Json 'SELECT * FROM rpt.FailedLogins ORDER BY EventTime DESC;') ; break }
                '^GET /api/logins$'      { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.LoginActivity ORDER BY ServerName, SessionCount DESC;') ; break }
                '^GET /api/staletables$' { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.StaleTables ORDER BY CASE Status WHEN ''CRIT'' THEN 0 WHEN ''WARN'' THEN 1 ELSE 2 END, SizeGB DESC;') ; break }
                '^GET /api/spectrum$'    { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.SpectrumByTable ORDER BY TBScanned DESC;') ; break }
                '^GET /api/costlyqueries$' { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.CostlyQueries ORDER BY EstCostUSD DESC, ScanGB DESC;') ; break }
                '^GET /api/servers$'  { Send-Json $ctx (Query-Json 'SELECT * FROM rpt.Servers ORDER BY IsActive DESC, Platform, ServerName;') ; break }
                '^POST /api/servers/delete$' {
                    $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd() | ConvertFrom-Json
                    Delete-Server ([int]$body.ServerID); Send-Json $ctx @{ ok = $true }; break
                }
                '^POST /api/servers/test$' {
                    $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd() | ConvertFrom-Json
                    Send-Json $ctx (Test-ServerConnection $body); break
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
                    # static file - resolve and CONTAIN under the web root so a
                    # crafted path (encoded traversal, etc.) can't escape www\.
                    $rel  = if ($path -eq '') { 'index.html' } else { $path.TrimStart('/') }
                    $root = [IO.Path]::GetFullPath($www).TrimEnd('\') + '\'
                    $file = [IO.Path]::GetFullPath((Join-Path $www $rel))
                    if ($file.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path $file -PathType Leaf)) {
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
