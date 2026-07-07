<#
    DBADash | Send-Alerts.ps1
    ---------------------------------------------------------------------------
    Emails active, not-yet-notified alerts. Two transports (config.alerting.transport):
       "dbmail" -> calls cfg.usp_Send_Alert_Email (SQL Server Database Mail)
       "smtp"   -> sends directly over SMTP from PowerShell (no Database Mail needed)

    Either way, rows are marked NotifiedAt so you are not re-spammed. Run after
    cfg.usp_Evaluate_Alerts (Collect-All does this for you).

    config.alerting example:
      "alerting": {
        "enabled": true,
        "transport": "smtp",
        "recipients": ["dba-team@corp.com"],
        "routeToOwners": true,
        "dbmailProfile": "DBADash",
        "smtp": { "host": "smtp.corp.com", "port": 25, "from": "dbadash@corp.com", "useSsl": false }
      }
#>
[CmdletBinding()]
param([string]$ConfigPath = "$PSScriptRoot\config\dbadash.json")
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.ps1"

$cfg = Get-DbaDashConfig -Path $ConfigPath
$a   = $cfg.alerting
if (-not ($a -and $a.enabled)) { Write-Host "Alerting disabled."; return }

$centralConn = Get-SqlConnString -Instance $cfg.central.sqlInstance -Database $cfg.central.database `
                                 -User $cfg.central.user -Password $cfg.central.password

# ---- Database Mail transport: let SQL Server do the sending ----
if ($a.transport -eq 'dbmail') {
    $recips = ($a.recipients -join ';')
    $q = "EXEC cfg.usp_Send_Alert_Email @ProfileName=N'$($a.dbmailProfile)', @Recipients=N'$recips';"
    [void](Invoke-SqlNonQuery -ConnString $centralConn -Query $q)
    Write-Host "Database Mail alert send requested." -ForegroundColor Green
    return
}

# ---- SMTP transport: build + send from PowerShell ----
$rows = Invoke-SqlQuery -ConnString $centralConn -Query @"
SELECT AlertID, Severity, Category, ServerName, Message, OwnerEmail
FROM rpt.ActiveAlerts
WHERE NotifiedAt IS NULL
ORDER BY CASE Severity WHEN 'CRIT' THEN 0 ELSE 1 END;
"@
if ($rows.Rows.Count -eq 0) { Write-Host "No new alerts to send."; return }

# recipient list = configured recipients (+ owner emails if routeToOwners)
$to = New-Object System.Collections.Generic.HashSet[string]
foreach ($r in $a.recipients) { if ($r) { [void]$to.Add([string]$r) } }
if ($a.routeToOwners) {
    foreach ($row in $rows.Rows) {
        $e = $row['OwnerEmail']; if ($e -and $e -isnot [DBNull]) { [void]$to.Add([string]$e) }
    }
}
if ($to.Count -eq 0) { Write-Warning "No recipients configured (alerting.recipients)."; return }

$crit = @($rows.Rows | Where-Object { $_['Severity'] -eq 'CRIT' }).Count
$sev  = { param($s) if ($s -eq 'CRIT') { '#c00' } else { '#c80' } }
$body = "<div style='font-family:Segoe UI,Arial,sans-serif'>" +
        "<h3 style='margin:0 0 8px'>DBADash &mdash; $($rows.Rows.Count) new alert(s)</h3>" +
        "<table cellpadding='6' cellspacing='0' border='1' style='border-collapse:collapse;font-size:13px'>" +
        "<tr style='background:#f0f0f0'><th>Severity</th><th>Category</th><th>Server</th><th>Detail</th></tr>"
foreach ($row in $rows.Rows) {
    $c = & $sev $row['Severity']
    $body += "<tr><td style='color:$c;font-weight:bold'>$($row['Severity'])</td>" +
             "<td>$($row['Category'])</td><td>$($row['ServerName'])</td><td>$($row['Message'])</td></tr>"
}
$body += "</table><p style='color:#888;font-size:12px'>DBADash · $(Get-Date -Format u)</p></div>"

$subject = "[DBADash] $($rows.Rows.Count) new alert(s)"
if ($crit -gt 0) { $subject += " ($crit CRITICAL)" }

$mailParams = @{
    SmtpServer = $a.smtp.host; Port = [int]$a.smtp.port
    From = $a.smtp.from; To = @($to)
    Subject = $subject; Body = $body; BodyAsHtml = $true
    UseSsl = [bool]$a.smtp.useSsl
}
Send-MailMessage @mailParams
Write-Host "Sent alert email to: $($to -join ', ')" -ForegroundColor Green

# mark as notified so we don't resend
$ids = ($rows.Rows | ForEach-Object { $_['AlertID'] }) -join ','
[void](Invoke-SqlNonQuery -ConnString $centralConn -Query `
    "UPDATE mon.AlertHistory SET NotifiedAt=SYSUTCDATETIME() WHERE AlertID IN ($ids);")
