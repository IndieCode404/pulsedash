# KIRO-AUTOMODEL — Master instruction file for DBADash Phase 1 (POC)

> **Purpose:** This file turns Kiro's AutoModel into a top-tier assistant for this
> project. It front-loads every convention, pitfall, and pattern so the model doesn't
> need expensive reasoning to figure them out. Put this file's path in Kiro's
> context (or paste key sections into your first message) to maximize output quality
> per credit spent.
>
> **Credit budget:** ~1000 credits/month. Every instruction here is designed to
> reduce round-trips and retries — the biggest credit drain.

---

## 1. What this project is

**DBADash** is a SQL-native DBA monitoring platform for MSSQL and Redshift.
- One central SQL Server database (`DBADash`) on one Windows Server box.
- Three schemas: `mon.*` (time-series), `cfg.*` (config/procs), `rpt.*` (reporting views).
- Agentless collection via PowerShell (CMS fan-out for MSSQL, ODBC for Redshift).
- Zero-dependency HTML dashboard (PowerShell `HttpListener`, inline SVG charts).
- Everything runs inside the client network. Nothing leaves. No telemetry.

**This folder is Phase 1 (POC scope only).** Phase 2 (advisor, bottlenecks, cost
anomaly, config audit, access control, index health) exists separately and will
merge later if the POC is approved.

---

## 2. Hard rules (NEVER violate)

1. **Nothing leaves the client network.** No outbound calls, no client data in prompts.
2. **Monitored targets are READ-ONLY.** SELECT only. Writes go to the central DB.
3. **Non-production instances only** until go/no-go approval.
4. **Windows PowerShell 5.1** — no `??`, no `?.`, no PS7 ternary, no `ForEach-Object -Parallel`.
5. **Zero external dependencies.** No npm, no CDN, no React in production.
6. **Parameterized SQL only.** Never string-concatenate values into queries.
7. **Escape all HTML output.** Every value goes through `esc()`. No raw `innerHTML`.
8. **DPAPI for secrets.** Plaintext passwords never reach the database.
9. **One task at a time.** Small diffs. Stop and checkpoint if it balloons.
10. **Edit, don't regenerate.** The prototype exists. Make targeted changes.

---

## 3. File map (know WHERE things are)

### SQL scripts (deployed in order by Deploy-DBADash.ps1)
| File | Creates |
|------|---------|
| `sql/01_create_database.sql` | `DBADash` DB + schemas |
| `sql/02_tables.sql` | Core tables: Servers, AGSyncStatus, DataLag, DiskUsage, etc. |
| `sql/04_procs_forecast.sql` | Disk forecast proc (least-squares) |
| `sql/05_views_dashboard.sql` | Core `rpt.*` views (Overview, BackupHealth, etc.) |
| `sql/06_appowners_crud.sql` | App owner CRUD procs |
| `sql/07_seed_demo.sql` | Demo data (optional, for testing) |
| `sql/08_growth.sql` | `mon.ObjectSize` + growth views |
| `sql/10_alerts.sql` | `mon.AlertHistory` + alert evaluation |
| `sql/12_health.sql` | Backups/CHECKDB, vitals, waits, alert eval v2, purge |
| `sql/14_servers_admin.sql` | Server admin procs, `rpt.Servers` |
| `sql/15_perf_logins.sql` | Top queries, failed logins, login inventory |
| `sql/16_connections.sql` | Connection fields on cfg.Servers (host/port/auth/DPAPI) |
| `sql/21_estate.sql` | Estate health grid (6 domains: Backup, Disk, Jobs, HA, Perf, Data) |

### PowerShell
| File | Does |
|------|------|
| `deploy/Common.ps1` | **Shared helpers** — read this FIRST for any PowerShell work |
| `deploy/Deploy-DBADash.ps1` | Creates/upgrades the central database |
| `deploy/Collect-All.ps1` | Main collector (CMS fan-out, post-processing) |
| `deploy/Collect-Redshift.ps1` | Redshift ODBC collector |
| `deploy/Show-Targets.ps1` | Dry-run: shows what servers would be contacted |
| `deploy/Package-DBADash.ps1` | Builds a runtime-only zip for deployment |
| `dashboard/Start-Dashboard.ps1` | Production dashboard (HttpListener on localhost) |

### Dashboard (HTML/CSS/JS)
| File | Does |
|------|------|
| `dashboard/www/index.html` | 10 tabs: Estate, AG, Lag, Health, Activity, Disk, Growth, Alerts, Owners, Servers |
| `dashboard/www/app.js` | All tab loaders, table renderer, KPI cards, SVG charts |
| `dashboard/www/styles.css` | CSS-var theme (light/dark toggle) |
| `dashboard/www/branding.json` | Client logo/name customization |

### Docs
| File | Purpose |
|------|---------|
| `docs/PORTABILITY.md` | SQL Server → Aurora PostgreSQL type/function map |
| `docs/SECURITY-CHECKLIST.md` | Security gate checklist (must pass before production) |
| `docs/KIRO-KICKOFF.md` | First-time Kiro kickoff prompt (paste into Kiro) |
| `ARCHITECTURE.md` | "One engine, many faces" design |
| `README.md` | Full setup guide |

---

## 4. KNOWN PITFALLS (already fixed — don't re-introduce)

These cost hours to debug. Read them before touching these areas.

### PowerShell 5.1
```powershell
# WRONG — PS 5.1 SqlConnectionStringBuilder does not support property syntax
$b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$b.DataSource = 'SERVER'  # THROWS: "Keyword not supported: DataSource"

# RIGHT — use the indexer form
$b['Data Source'] = 'SERVER'
$b['Initial Catalog'] = 'DBADash'
$b['Integrated Security'] = 'True'
```

```powershell
# WRONG — PS7-isms that fail in 5.1
$x = $null ?? 'default'           # parse error
$x = $obj?.Property               # parse error
$results | ForEach-Object -Parallel { }  # not available

# RIGHT
$x = if ($null -eq $val) { 'default' } else { $val }
if ($null -ne $obj) { $obj.Property }
```

```powershell
# WRONG — Redshift ODBC driver name comes back as PSObject, not string
$driver = Get-OdbcDriver ... | Select -First 1 -Expand Name
# Then using $driver in a string silently produces garbage

# RIGHT — cast to [string]
$driver = [string](Get-OdbcDriver ... | Select -First 1 -Expand Name)
```

### SQL Server
```sql
-- WRONG — SqlBulkCopy column mapping is CASE-SENSITIVE
-- If your query returns 'servername' but the table has 'ServerName', it silently drops rows

-- RIGHT — Write-BulkTable in Common.ps1 handles this with case-insensitive mapping.
-- Always use Write-BulkTable, never raw SqlBulkCopy.
```

```sql
-- WRONG — DMVs that don't exist on older SQL versions crash the whole collection cycle
SELECT * FROM sys.dm_os_host_info  -- SQL 2017+ only
SELECT * FROM sys.dm_db_log_info(DB_ID())  -- SQL 2016 SP2+ only

-- RIGHT — wrap in TRY/CATCH dynamic SQL that returns an empty typed result set on failure
BEGIN TRY
  EXEC sp_executesql N'SELECT ... FROM sys.dm_os_host_info'
END TRY
BEGIN CATCH
  SELECT CAST(NULL AS NVARCHAR(128)) AS host_platform, ...
END CATCH
```

```sql
-- WRONG — ISNULL on nullable vitals going into NOT NULL columns
INSERT INTO mon.Vitals (PLE, ...) SELECT ple FROM ...
-- If ple is NULL, INSERT fails on a NOT NULL column

-- RIGHT
INSERT INTO mon.Vitals (PLE, ...) SELECT ISNULL(ple, 0) FROM ...
```

### Dashboard (HTML/JS)
```javascript
// WRONG — rendering collected data without escaping
cell.innerHTML = row.ServerName;  // XSS if ServerName contains <script>

// RIGHT — always use esc()
cell.innerHTML = esc(row.ServerName);

// The esc() function is defined at the top of app.js:
// function esc(s) { ... escapes & < > " }
```

---

## 5. HOW TO do common tasks (copy-paste recipes)

### Add a new collector query (MSSQL)

**Step 1 — Define the table** in a new or existing `sql/NN_*.sql`:
```sql
CREATE TABLE mon.NewMetric (
    CollectedAt   DATETIME2(0) NOT NULL,
    ServerName    NVARCHAR(128) NOT NULL,
    -- your columns --
    MetricValue   DECIMAL(18,2) NOT NULL
);
```

**Step 2 — Add the query** in `deploy/Collect-All.ps1` as a here-string:
```powershell
$Q_NEWMETRIC = @'
SELECT
    col1,
    col2
FROM sys.dm_whatever
'@
```

**Step 3 — Add the bulk-write call** in the per-instance loop in `Collect-All.ps1`:
```powershell
$rows = Invoke-SqlQuery -Conn $targetConn -Sql $Q_NEWMETRIC
Write-BulkTable -Data (Add-Envelope $rows $inst) `
                -Table 'mon.NewMetric' -ConnStr $centralCs
```

**Step 4 — Add a reporting view** in an existing or new `sql/NN_*.sql`:
```sql
CREATE OR ALTER VIEW rpt.NewMetricView AS
SELECT ... FROM mon.NewMetric
WHERE CollectedAt = (SELECT MAX(CollectedAt) FROM mon.NewMetric WHERE ServerName = m.ServerName);
```

**Step 5 — Add to purge** in the LATEST purge proc (currently in `sql/12_health.sql`):
```sql
DELETE FROM mon.NewMetric WHERE CollectedAt < @cutoff;
```

**Step 6 — Add to deploy script list** in `deploy/Deploy-DBADash.ps1` `$scripts` array.

### Add a new dashboard tab

**Step 1** — Add button in `dashboard/www/index.html`:
```html
<button class="tab" data-tab="newtab">New Tab</button>
```

**Step 2** — Add panel section:
```html
<section id="tab-newtab" class="panel">
  <div class="panel-head"><h2>New Tab Title</h2></div>
  <div id="newTabTable" class="tablewrap"></div>
</section>
```

**Step 3** — Add loader in `dashboard/www/app.js`:
```javascript
async function loadNewTab() {
  const rows = await api('/api/newmetric');
  table(newTabTable, rows, ['ServerName','MetricValue','CollectedAt']);
}
```

**Step 4** — Add to `refreshActive` map:
```javascript
newtab: loadNewTab,
```

### Add a Redshift collector query

**Step 1** — Add the SQL block to `redshift/redshift_metrics.sql`:
```sql
--==NEW_METRIC==--
SELECT ... FROM svv_something;
```

**Step 2** — In `deploy/Collect-Redshift.ps1`, add the call:
```powershell
$sqlNew = Get-SqlBlock $metricsFile 'NEW_METRIC'
# ... invoke via ODBC and Write-BulkTable
```

---

## 6. Credit-saving strategies for Kiro AutoModel

### DO (saves credits)
- **Start every session by pointing Kiro to this file and the steering files.**
  The steering is always-loaded (free context). This file goes as initial context.
- **Ask for ONE specific change per request.** "Add a PLE threshold check in
  `sql/12_health.sql` line 45, change the WARN from 300 to 500" — not "improve
  the health checks."
- **Include the file path and line numbers.** AutoModel wastes credits searching
  if you don't tell it where to look.
- **Use the recipes above.** "Follow the 'Add a new collector query' recipe in
  KIRO-AUTOMODEL.md to add a TempDB free-space collector" — the model follows
  structured recipes well.
- **Paste error text directly.** "I got this error when running Collect-All.ps1:
  `[error text]`. Fix it." — faster than asking the model to guess.
- **Use the cheapest model for simple edits** (rename, add a column, fix a typo).
  Escalate to a bigger model only for architectural reasoning.

### DON'T (wastes credits)
- **Don't ask it to "review the whole codebase"** — that's a multi-file scan that
  burns credits and produces generic observations.
- **Don't ask it to "rewrite" or "rebuild" a file** — edit the specific lines.
- **Don't leave agent-on-save hooks running** — every save re-invokes the model.
- **Don't ask open-ended questions** like "what should we build next" — that's a
  conversation, not a task. Think first, then ask for the specific implementation.
- **Don't retry the same failing prompt** — if it fails twice, the ask is probably
  too big. Break it down.

### Session template (paste as first message)
```
Context: DBADash Phase 1 POC. Read .kiro/steering/ for guardrails. Read
KIRO-AUTOMODEL.md for conventions and pitfalls. I need to [specific task].

The file to edit is [path/to/file.ps1], around line [N].

[What to change and why.]
```

---

## 7. Supersession pattern (IMPORTANT)

Some procs/views are re-defined by later `sql/NN` files. The LAST one wins because
`Deploy-DBADash.ps1` runs scripts in order. In Phase 1:

| Object | Live definition | Note |
|--------|----------------|------|
| `cfg.usp_Evaluate_Alerts` | `sql/12_health.sql` | Scans rpt.* views, raises alerts |
| `rpt.Overview` | `sql/05_views_dashboard.sql` | KPI summary view |
| `cfg.usp_Purge_History` | `sql/12_health.sql` | Deletes old mon.* rows |
| `rpt.InstanceVitals` | `sql/02_tables.sql` | Base vitals view |

**When you add a new `mon.*` table:** add it to the purge proc in the highest-
numbered file that defines it. Currently that's `sql/12_health.sql`.

**When you add a new KPI:** update `rpt.Overview` in the highest-numbered file
that defines it. Currently `sql/05_views_dashboard.sql`.

---

## 8. The three engine seams (portability)

The ONLY SQL-Server-specific code in the store layer is in `deploy/Common.ps1`:

| Seam | Function | SQL Server today | Aurora PostgreSQL later |
|------|----------|-----------------|----------------------|
| Connection | `Get-SqlConnString` | `SqlConnectionStringBuilder` | Npgsql builder |
| Bulk ingest | `Write-BulkTable` | `SqlBulkCopy` | Npgsql `COPY` |
| Secret store | `Protect/Unprotect-DbaDashSecret` | DPAPI | AWS Secrets Manager |

**Rule:** No other file may open a connection, bulk-load, or handle a secret
directly. If you need to do any of these, use the helper in `Common.ps1`.

---

## 9. Dashboard conventions

- **10 tabs** (Phase 1): Estate, AG Sync, Data Lag, Health, Activity, Disk Forecast,
  Growth, Alerts, App Owners, Servers.
- **KPI cards** in `loadKpis()` are clickable — they route to tabs via `data-tab`.
- **Estate grid** has 6 domain columns: Backup, Disk, Jobs, HA, Perf, Data.
  Status values: OK / WRN / CRT / – (not applicable).
- **Table renderer** (`table()`) handles column rendering. Pass column names as an
  array: `table(container, rows, ['Col1','Col2','Col3'])`.
- **SVG charts** are inline — no Chart.js, no D3. The growth chart is in `drawGrowth()`.
- **Theme** toggle: light/dark via CSS vars + localStorage. Light overrides are under
  `[data-theme="light"]` in `styles.css`.
- **Branding:** `www/branding.json` — `productName`, `tagline`, `logoUrl`.
- **CSRF:** POST APIs require `X-DBADash` header + same-origin `Origin`.

---

## 10. Testing without SQL Server

There is no SQL Server on the dev machine. Validate like this:

**PowerShell syntax check:**
```powershell
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  'deploy\Collect-All.ps1', [ref]$null, [ref]$errs)
$errs  # should be empty
```

**JavaScript syntax check:**
```bash
node --check dashboard/www/app.js
```

**SQL — can't execute, but:**
- Read the file and confirm syntax (SELECT, CREATE OR ALTER, parameterization).
- Check that new tables are added to the purge proc.
- Check that new views follow ANSI patterns (COALESCE not ISNULL, CASE not IIF).
- **Always tell the user** the SQL needs a real instance to validate.

---

## 11. Deployment quick reference

```powershell
# 1. Deploy the central database
cd deploy
.\Deploy-DBADash.ps1

# 2. Dry-run (what servers would we contact?)
.\Show-Targets.ps1

# 3. First collection
.\Collect-All.ps1

# 4. Check collection log
# SELECT * FROM DBADash.cfg.CollectionLog ORDER BY RunAt DESC

# 5. Start the dashboard
cd ..\dashboard
.\Start-Dashboard.ps1
# Browse to http://localhost:8080

# 6. Package for another box
cd ..\deploy
.\Package-DBADash.ps1
```

---

## 12. What NOT to do (scope boundary)

These are Phase 2 features. They exist in a separate archive. Do not build them
into this codebase:

- Advisor (root-cause findings engine)
- Bottlenecks (file I/O latency, wait deltas, autogrowth)
- Cost anomaly detection / costly queries / stale tables / Spectrum analysis
- Server & config audit (patch level, config drift)
- Access control (login classification)
- Index health (missing/unused indexes)
- SMTP alert sender (`Send-Alerts.ps1`)

If a client asks about these, say they're planned for Phase 2 — don't code them.

---

## 13. Multi-engine evolution (architecture awareness)

The POC monitors MSSQL + Redshift, but the architecture is designed to extend to
**Oracle, Aurora PostgreSQL, Db2, and Couchbase**. See `docs/EVOLUTION.md` for the
full roadmap. Key points for any model working on this code:

- **`cfg.Servers.Platform`** identifies the engine. New engine = new platform value.
- **`mon.*` tables are engine-agnostic** — keyed by `ServerName` + `CollectedAt`.
  Oracle tablespaces → `mon.DiskUsage`, Data Guard → `mon.DataLag`, etc.
- **Each engine gets its own `Collect-*.ps1`** — never mix engine-specific SQL into
  another engine's collector.
- **Estate grid works across engines** — domain rules branch by Platform.
- **8 universal metrics** normalize across all engines: storage, replication lag,
  backup recency, sessions, vitals, failed logins, object sizes, collection log.

**Don't build other engine collectors now.** But if you modify schema, views, or
the dashboard, keep the multi-engine path open:
- Don't hardcode "MSSQL" or "Redshift" assumptions in `rpt.*` views — use the
  `Platform` column where engine-specific logic is needed.
- Don't add engine-specific tabs without a `data-engine` attribute for show/hide.
- Don't add connection logic outside `Common.ps1`.
