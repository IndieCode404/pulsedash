<#
    DBADash | Common.ps1
    Shared helpers for deploy + collectors. Dot-source this:  . "$PSScriptRoot\Common.ps1"
    Uses only System.Data (SqlClient + Odbc) so there are NO PowerShell module
    dependencies - runs on a stock Windows box with SQL Server tools.
#>

Add-Type -AssemblyName System.Data | Out-Null

function Get-DbaDashConfig {
    param([string]$Path = "$PSScriptRoot\config\dbadash.json")
    if (-not (Test-Path $Path)) {
        throw "Config not found: $Path  (copy config\dbadash.example.json to dbadash.json and edit it)"
    }
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

# Build a SQL Server connection string. Empty user => Windows/Integrated auth.
function Get-SqlConnString {
    param([string]$Instance, [string]$Database = 'master', [string]$User, [string]$Password)
    $cs = "Server=$Instance;Database=$Database;TrustServerCertificate=True;Connect Timeout=15;Application Name=DBADash;"
    if ([string]::IsNullOrWhiteSpace($User)) { $cs += "Integrated Security=SSPI;" }
    else { $cs += "User ID=$User;Password=$Password;" }
    return $cs
}

# Run a query against SQL Server and return a DataTable (empty table if no rows).
function Invoke-SqlQuery {
    param([string]$ConnString, [string]$Query, [int]$TimeoutSec = 60)
    $conn = New-Object System.Data.SqlClient.SqlConnection $ConnString
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = $TimeoutSec
        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        return ,$dt
    } finally { $conn.Dispose() }
}

# Run a non-query (or scalar-ish) statement against SQL Server.
function Invoke-SqlNonQuery {
    param([string]$ConnString, [string]$Query, [int]$TimeoutSec = 120)
    $conn = New-Object System.Data.SqlClient.SqlConnection $ConnString
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = $TimeoutSec
        return $cmd.ExecuteNonQuery()
    } finally { $conn.Dispose() }
}

# Bulk-load a DataTable into a central table. DataTable column names must match
# the destination column names (mapped by name, so column order is irrelevant).
function Write-BulkTable {
    param([string]$ConnString, [System.Data.DataTable]$Table, [string]$Destination)
    if ($Table.Rows.Count -eq 0) { return 0 }
    $bulk = New-Object System.Data.SqlClient.SqlBulkCopy($ConnString)
    try {
        $bulk.DestinationTableName = $Destination
        foreach ($col in $Table.Columns) {
            [void]$bulk.ColumnMappings.Add($col.ColumnName, $col.ColumnName)
        }
        $bulk.WriteToServer($Table)
        return $Table.Rows.Count
    } finally { $bulk.Close() }
}

# Append the shared "envelope" columns onto a raw result set. Platform is only
# added when supplied (mon.AGSyncStatus has no Platform column, mon.DiskUsage does).
function Add-Envelope {
    param([System.Data.DataTable]$Table, [string]$ServerName, [string]$Platform, [datetime]$CollectedAt)
    if (-not $Table.Columns.Contains('ServerName'))  { [void]$Table.Columns.Add('ServerName',  [string]) }
    if (-not $Table.Columns.Contains('CollectedAt')) { [void]$Table.Columns.Add('CollectedAt', [datetime]) }
    if ($Platform -and -not $Table.Columns.Contains('Platform')) { [void]$Table.Columns.Add('Platform', [string]) }
    foreach ($row in $Table.Rows) {
        $row['ServerName']  = $ServerName
        $row['CollectedAt'] = $CollectedAt
        if ($Platform) { $row['Platform'] = $Platform }
    }
    return ,$Table
}

# Write a row to cfg.CollectionLog on the central server.
function Write-CollectionLog {
    param([string]$CentralConn, [string]$Collector, [string]$ServerName,
          [string]$Status, [int]$RowsLoaded = 0, [string]$Message = '')
    $q = @"
INSERT DBADash.cfg.CollectionLog (Collector, ServerName, Status, RowsLoaded, Message)
VALUES (@c, @s, @st, @r, @m);
"@
    $conn = New-Object System.Data.SqlClient.SqlConnection $CentralConn
    try {
        $conn.Open(); $cmd = $conn.CreateCommand(); $cmd.CommandText = $q
        $srv = if ([string]::IsNullOrEmpty($ServerName)) { [DBNull]::Value } else { $ServerName }
        $msg = if ($null -eq $Message) { '' } else { $Message }
        [void]$cmd.Parameters.AddWithValue('@c',  $Collector)
        [void]$cmd.Parameters.AddWithValue('@s',  $srv)
        [void]$cmd.Parameters.AddWithValue('@st', $Status)
        [void]$cmd.Parameters.AddWithValue('@r',  $RowsLoaded)
        [void]$cmd.Parameters.AddWithValue('@m',  $msg)
        [void]$cmd.ExecuteNonQuery()
    } catch { Write-Warning "log write failed: $($_.Exception.Message)" }
      finally { $conn.Dispose() }
}

# Upsert a row into cfg.Servers so the inventory / Overview KPIs stay accurate.
function Register-Server {
    param([string]$CentralConn, [string]$ServerName, [string]$Platform,
          [string]$Environment = 'PROD', [string]$FriendlyName = $null)
    $q = @"
MERGE DBADash.cfg.Servers AS t
USING (SELECT @n AS ServerName) AS s ON t.ServerName = s.ServerName
WHEN MATCHED THEN UPDATE SET Platform=@p, Environment=@e, IsActive=1,
     FriendlyName=COALESCE(@f, t.FriendlyName)
WHEN NOT MATCHED THEN INSERT (ServerName, Platform, Environment, FriendlyName)
     VALUES (@n, @p, @e, @f);
"@
    $conn = New-Object System.Data.SqlClient.SqlConnection $CentralConn
    try {
        $conn.Open(); $cmd = $conn.CreateCommand(); $cmd.CommandText = $q
        [void]$cmd.Parameters.AddWithValue('@n', $ServerName)
        [void]$cmd.Parameters.AddWithValue('@p', $Platform)
        [void]$cmd.Parameters.AddWithValue('@e', $Environment)
        $fn = if ([string]::IsNullOrEmpty($FriendlyName)) { [DBNull]::Value } else { $FriendlyName }
        [void]$cmd.Parameters.AddWithValue('@f', $fn)
        [void]$cmd.ExecuteNonQuery()
    } finally { $conn.Dispose() }
}

# Run a query against Redshift via ODBC and return a DataTable.
function Invoke-OdbcQuery {
    param([string]$ConnString, [string]$Query, [int]$TimeoutSec = 60)
    $conn = New-Object System.Data.Odbc.OdbcConnection $ConnString
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $Query; $cmd.CommandTimeout = $TimeoutSec
        $da = New-Object System.Data.Odbc.OdbcDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        return ,$dt
    } finally { $conn.Dispose() }
}

# Pull one named block (--==NAME==-- ... ) out of redshift_metrics.sql.
function Get-SqlBlock {
    param([string]$Path, [string]$Name)
    $text = Get-Content -Raw -Path $Path
    $m = [regex]::Match($text, "(?ms)--==$Name==--\s*(.*?)(?=^--==|\z)")
    if (-not $m.Success) { throw "SQL block '$Name' not found in $Path" }
    return $m.Groups[1].Value.Trim()
}

# Enumerate instances registered under a CMS group (reads msdb shared reg servers).
function Get-CmsRegisteredServers {
    param([string]$CmsInstance, [string]$Group)
    $q = @"
;WITH g AS (
    SELECT server_group_id FROM msdb.dbo.sysmanagement_shared_server_groups_internal
    WHERE name = @grp
)
SELECT s.server_name
FROM msdb.dbo.sysmanagement_shared_registered_servers_internal s
WHERE s.server_group_id IN (SELECT server_group_id FROM g);
"@
    $conn = New-Object System.Data.SqlClient.SqlConnection (Get-SqlConnString -Instance $CmsInstance -Database 'msdb')
    try {
        $conn.Open(); $cmd = $conn.CreateCommand(); $cmd.CommandText = $q
        [void]$cmd.Parameters.AddWithValue('@grp', $Group)
        $r = $cmd.ExecuteReader(); $list = @()
        while ($r.Read()) { $list += $r['server_name'] }
        return $list
    } finally { $conn.Dispose() }
}
