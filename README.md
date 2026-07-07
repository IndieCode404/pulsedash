# DBADash — MSSQL & Redshift monitoring dashboard

A one-stop DBA health desk for **SQL Server** and **Amazon Redshift**, built the
way a consultant would ship it: a central monitoring database, T-SQL collectors
fanned out through your **Central Management Server (CMS)**, PowerShell for the
Redshift side, a nightly forecast, a zero-dependency HTML dashboard, and email
alerting that routes to your app owners.

It answers the questions clients actually ask on day one:

1. **Are my Availability Groups healthy?** — AG sync state + health per database.
2. **How far behind is my data?** — AG redo lag (MSSQL) and ETL load freshness (Redshift), in one unified view.
3. **When do my disks fill up?** — least-squares growth forecast → *days to full* + a *"buy N GB"* recommendation.
4. **How fast are my databases/tables growing?** — per-database (MSSQL) and per-table (Redshift) size history on an SVG **growth chart** + a top-movers grid.
5. **Is my Redshift bill about to spike?** — in-cluster **cost-anomaly detection** (z-score vs. 14-day rolling baseline) on scan/Spectrum/storage drivers. See [docs/COST_ANOMALY.md](docs/COST_ANOMALY.md).
6. **Who do I call, and how do I get told?** — an app-owner directory you edit from a form, plus **email alerting** (Database Mail *or* SMTP) routed to the owner.
7. **Can I restore, and is my data intact?** — backup RPO health per database (full/diff/log ages vs. recovery model), **last good DBCC CHECKDB**, offline/suspect database states, and Agent job failures.
8. **What's hurting right now?** — instance vitals (PLE, memory grants pending, blocked sessions, deadlocks), live **blocking chains** & long-running queries, top waits, top queries by CPU, and Redshift WLM queue depth, load errors, and **VACUUM/ANALYZE debt**.
9. **Who is on my server and who keeps failing to log in?** — failed-login audit (MSSQL error log + Redshift connection log) and a live session inventory showing host, app, login, and duration.
10. **Am I paying for Redshift storage I never read?** — **stale table detection** (last-scan age vs. your threshold) with $/month reclaim estimate, plus a **Spectrum per-external-table cost** breakdown.

Runs on **SQL Server + PowerShell only**. No Node, no IIS, no licenses.

---

## Architecture

```
   ┌──────────── Monitored fleet ────────────┐
   │  MSSQL (AGs + standalone)   Redshift     │
   └──────┬───────────────────────┬───────────┘
          │ CMS fan-out (T-SQL)   │ ODBC (PowerShell)
          ▼                       ▼
   deploy\Collect-All.ps1  →  deploy\Collect-Redshift.ps1
          │                       │
          └──────────┬────────────┘
                     ▼
        ┌──────────────────────────┐
        │  DBADash  (central DB)    │
        │  mon.*  time-series       │
        │  cfg.*  inventory+owners  │
        │  rpt.*  dashboard views   │
        └──────────┬───────────────┘
                   ▼
   dashboard\Start-Dashboard.ps1  ──►  HTML/CSS UI   (also: Power BI / SSRS)
   (SQL Agent job runs Collect-All every 15 min)
```

## What's in the box

| Path | Purpose |
|------|---------|
| `sql\01_create_database.sql` | Creates the DBADash DB with mon/cfg/rpt schemas |
| `sql\02_tables.sql` | Core tables: Servers, AGSyncStatus, DataLag, DiskUsage, DiskForecast, AppOwners, CollectionLog |
| `sql\03_collect_mssql.sql` | **Target-side** MSSQL collection queries (run by CMS fan-out; also runnable by hand in SSMS) |
| `sql\04_procs_forecast.sql` | Disk forecast (least-squares) + purge stored procedures |
| `sql\05_views_dashboard.sql` | Core `rpt.*` views consumed by dashboard + Power BI |
| `sql\06_appowners_crud.sql` | App owner CRUD (`cfg.usp_AppOwner_Upsert`, `cfg.usp_AppOwner_Delete`) |
| `sql\08_growth.sql` | DB/table size time-series (`mon.ObjectSize`) + `rpt.GrowthKeys` view |
| `sql\09_cost.sql` | Redshift cost-driver capture (`mon.RedshiftCost`) + z-score anomaly detection proc |
| `sql\10_alerts.sql` | Alert evaluation/dedup (`mon.AlertHistory`, `usp_Evaluate_Alerts`) + Database Mail sender |
| `sql\12_health.sql` | Proactive health: backups/CHECKDB, job failures, vitals, query snapshots, waits, Redshift table health (alert eval v2) |
| `sql\14_servers_admin.sql` | `cfg.usp_Server_Upsert`, `usp_Server_Delete`, `rpt.Servers` (last collection status) |
| `sql\15_perf_audit_cost.sql` | Top queries by CPU, failed-login audit, session inventory, stale-table detection, Spectrum scans |
| `sql\16_connections.sql` | Adds connection fields to `cfg.Servers`: Host, Port, DatabaseName, AuthType, UserName, PasswordEnc (DPAPI blob) |
| `sql\07`, `sql\11`, `sql\13` | Optional demo seeds: core → growth/cost/alerts → health/activity |
| `redshift\redshift_metrics.sql` | Redshift SQL blocks: DISK, FRESHNESS, TABLE_SIZE, TABLE_HEALTH, ACTIVITY, RS_VITALS, TABLE_SCAN, SPECTRUM, RS_LOGINS, COST |
| `deploy\Deploy-DBADash.ps1` | Builds / upgrades the central database (runs numbered SQL scripts in order) |
| `deploy\Collect-All.ps1` | Main collector: CMS fan-out, forecast refresh, cost anomaly, alert eval, purge |
| `deploy\Collect-Redshift.ps1` | Redshift ODBC collector: disk, freshness, sizes, cost, table health, queries, vitals, stale tables, Spectrum, failed logins |
| `deploy\Send-Alerts.ps1` | Emails active alerts (SMTP or Database Mail) |
| `deploy\Common.ps1` | Shared helpers: config loader, SQL helpers, DPAPI encrypt/decrypt — no external module deps |
| `deploy\config\dbadash.example.json` | Copy to `dbadash.json`, edit with your instance + cluster details |
| `agent\Create-AgentJobs.sql` | Creates the **"DBADash - Collect"** SQL Agent job |
| `dashboard\Start-Dashboard.ps1` + `www\` | Self-contained PowerShell HTTP server + HTML/CSS/JS dashboard (10 tabs) |
| `powerbi\`, `ssrs\` | Connect Power BI / SSRS to the same `rpt.*` views |
| `docs\COST_ANOMALY.md` | Redshift cost-anomaly playbook: AWS-native vs. in-cluster approaches |

---

## Setup (about 15 minutes)

### 0. Prerequisites
- A **central SQL Server** instance to host `DBADash` (Express is fine).
- A **CMS** with your MSSQL instances registered in a group (e.g. `PROD-SQL`).
  *No CMS? List instances in `mssqlInstances` in the config instead, or add them
  via the dashboard Servers tab.*
- For Redshift: an **ODBC driver** on the collector box — *Amazon Redshift ODBC (x64)*
  (recommended) or *PostgreSQL Unicode(x64)*.
- The collector account needs **VIEW SERVER STATE** + **db_datareader on msdb** on
  every MSSQL target, and **db_datawriter** on `DBADash`.

### 1. Configure
```powershell
cd K:\DBA_Monitoring\DBADash\deploy\config
copy dbadash.example.json dbadash.json
notepad dbadash.json   # set central instance, CMS group, Redshift cluster(s)
```
Tip: keep Redshift passwords out of the file — set `$env:DBADASH_RS_PWD` instead,
or add the cluster via the dashboard **Servers** tab and let DPAPI handle it.

### 2. Build the central database
```powershell
cd K:\DBA_Monitoring\DBADash\deploy
.\Deploy-DBADash.ps1                 # schema only
.\Deploy-DBADash.ps1 -WithDemoData   # OR: schema + demo data to see it working first
```

### 3. Run a collection (once, by hand)
```powershell
.\Collect-All.ps1
```
Check `SELECT * FROM DBADash.cfg.CollectionLog ORDER BY RunAt DESC;` — every
instance should show `OK`. Unreachable servers log an `ERROR` row and the run
continues.

### 3b. Adding servers — where do connection strings go?

MSSQL targets are merged from **three sources**; the collector picks them all up
every run:

| How | Where | Auth |
|-----|-------|------|
| **CMS group** (best for fleets) | Register instances in SSMS under Central Management Servers → set `cms.group` in config | Windows auth |
| **Dashboard Servers tab** | Click *+ Add server* → fill in the DBeaver-style form → Save | Windows *or* SQL auth + DPAPI |
| **Config list** (`cms.mssqlInstances`) | Plain strings for Windows auth, or `{ "instance":"…", "user":"…", "passwordEnvVar":"…" }` objects for SQL auth | Either |

**Redshift clusters** can also be added via the Servers tab (pick Platform = Redshift
and fill in Host / Port / Database / credentials). The collector merges config-file
clusters and Servers-tab clusters; config wins on clusterId collisions.

Passwords entered via the Servers tab are encrypted with **Windows DPAPI
(LocalMachine scope)** before being stored in `cfg.Servers.PasswordEnc`. The
plaintext never reaches the database, and the blob is useless outside the
collector machine — identical to how tools like SSMS save passwords locally.

To pause a server: set it **No — paused** on the Servers tab. To remove it from
collection: Delete (this does not drop its historical data).

### 4. Schedule it
Open `agent\Create-AgentJobs.sql` in SSMS, edit `@ScriptPath` / `@IntervalMinutes`,
run it. Creates the **"DBADash - Collect"** job (default: every 15 min).

### 5. Open the dashboard
```powershell
cd K:\DBA_Monitoring\DBADash\dashboard
.\Start-Dashboard.ps1
# browse to http://localhost:8080
```
*(Prefer Power BI or SSRS? See `powerbi\` / `ssrs\` — same `rpt.*` views.)*

The dashboard has **10 tabs**:

| Tab | What you see |
|-----|-------------|
| **AG Sync** | AG name, primary/secondary, sync state, health per database |
| **Data Lag** | AG redo lag (MSSQL) + ETL load freshness (Redshift) in seconds |
| **Health** | Backup RPO, CHECKDB age, job failures (7 days), failed-login audit, session inventory |
| **Activity** | Instance vitals, blocking/long-running queries, top waits, Redshift table maintenance, top 10 queries by CPU |
| **Disk Forecast** | Days-to-full per volume + "buy N GB" sizing for 180-day headroom |
| **Growth** | SVG trend chart (per DB or per Redshift table) + top-movers grid (GB/day) |
| **Cost Anomaly** | Redshift cost-driver z-score vs. baseline, stale tables with $/month reclaim, Spectrum per-external-table cost |
| **Alerts** | Active CRIT/WARN conditions with severity, category, affected server |
| **App Owners** | Editable app-owner directory: server, DB, tier, owner, email, on-call |
| **Servers** | Monitored server inventory: platform, environment, last collection status; + **DBeaver-style connection form** |

The **header KPI cards** are clickable — they navigate directly to the relevant
tab. Keyboard-accessible (Tab + Enter).

**Proactive thresholds** (all tunable in `sql\12_health.sql`):
- **Backups** — CRIT: database not ONLINE, no full backup in 7 days, or (FULL recovery) no log backup in 6 h; WARN: full > 2 days, log > 1 h, CHECKDB > 30 days, `page_verify ≠ CHECKSUM`, or `AUTO_SHRINK = ON`.
- **Vitals** — PLE < 300 s WARN / < 100 CRIT; memory grants pending > 0 WARN / ≥ 5 CRIT; blocked sessions > 0 WARN / ≥ 5 CRIT; deadlocks detected; Redshift queued queries or load errors > 0 WARN.
- **Queries** — blocked session CRIT; runtime ≥ 10 min WARN.
- **Redshift tables** — unsorted or stats_off ≥ 20 % WARN / ≥ 50 % CRIT (run VACUUM/ANALYZE).

All thresholds feed `cfg.usp_Evaluate_Alerts`, so email alerting covers the full
morning checklist (Backup / Job / Vitals / TableHealth categories).

### 6. (Optional) Turn on email alerts
In `dbadash.json` set `alerting.enabled = true` and pick a transport:
- **`smtp`** — `Send-Alerts.ps1` sends directly; fill in `alerting.smtp`.
- **`dbmail`** — uses SQL Server Database Mail; set `alerting.dbmailProfile`
  (configure a Database Mail profile first) and it calls `cfg.usp_Send_Alert_Email`.

`Collect-All.ps1` evaluates alerts every run and, when enabled, sends any **new**
CRIT/WARN conditions (deduped so you're not re-spammed). Set `routeToOwners: true`
to also email the affected app's owner from `cfg.AppOwners`.

---

## How the pieces work

**AG sync & lag** come from `sys.dm_hadr_database_replica_states`. Lag is computed
as `DATEDIFF(second, secondary.last_commit_time, primary.last_commit_time)` per
database — a true "seconds of data behind", not just queue size.

**Disk forecast** (`cfg.usp_Refresh_DiskForecast`) fits a least-squares line to
each volume's `UsedBytes` history over the last 30 days:
`slope = (nΣxy − ΣxΣy) / (nΣx² − (Σx)²)`. `DaysToFull = free / slope`;
`RecommendedAddGB` sizes for ~180 days of headroom. Severity: **CRIT** ≤14 days,
**WARN** ≤45 days.

**Redshift** disk comes from `stv_partitions`; load freshness from a best-effort
`stl_insert`/`stl_query` join. **Edit `redshift\redshift_metrics.sql`** to match
how your pipeline lands data (or use `SYS_LOAD_HISTORY` on RA3/Serverless).

**Growth** is tracked in `mon.ObjectSize` — per-database for MSSQL
(`sys.master_files`) and per-table for Redshift (`svv_table_info`). The dashboard
draws the series as a dependency-free inline SVG line chart; `rpt.GrowthKeys`
gives the top-movers grid (current size + GB/day).

**Cost anomaly** (`cfg.usp_Detect_CostAnomaly`) keeps a 14-day rolling baseline
per Redshift cost driver (Spectrum TB scanned, bytes scanned, storage) and flags
today with a z-score: **WARN** at z≥2.5 or +50%, **CRIT** at z≥4 or +100%.
Pair it with AWS Cost Anomaly Detection for invoice truth — full playbook in
[docs/COST_ANOMALY.md](docs/COST_ANOMALY.md).

**Stale tables** (`rpt.StaleTables`) snapshot last-scan timestamps from Redshift
`stl_scan` into `mon.TableScan` every collection cycle, accumulating history
beyond Redshift's built-in STL retention window. A table not scanned for N days
(threshold configurable in the view) appears with an estimated $/month storage
cost — a candidate for archiving or dropping.

**Spectrum cost** (`rpt.SpectrumByTable`) reads `svl_s3query_summary` to surface
external-table S3 scans from the last 24 h with an estimated cost at ~$5/TB.

**Query performance** (`rpt.TopQueries`) captures the top 10 statements from
`sys.dm_exec_query_stats` by total CPU time, limited to plans active in the last
24 h. Used as a fast daily "who is hurting the CPU" view without enabling Query
Store.

**Login audit** (`rpt.FailedLogins`, `rpt.LoginActivity`) reads the MSSQL error
log for failed authentication attempts and queries `sys.dm_exec_sessions` for the
live session inventory (login, host, app, database, duration). Redshift failed
logins come from `stl_connection_log WHERE event = 'authentication failure'`.

**Alerts** (`cfg.usp_Evaluate_Alerts`) scans every `rpt.*` view, keeps one active
row per problem in `mon.AlertHistory` (auto-resolving cleared conditions), and
feeds the Alerts tab + email. **App owners** live in `cfg.AppOwners`; the
dashboard form calls `cfg.usp_AppOwner_Upsert`, and Power BI / SSRS read the same
table, so everything stays in sync.

---

## Security notes
- Grant the collector a **dedicated login with least privilege**: VIEW SERVER STATE
  + db_datareader on msdb on each target; db_datawriter on DBADash. No sysadmin.
- Use a **Redshift read-only** user. Never commit its password to the JSON config —
  use `$env:DBADASH_RS_PWD` or add the cluster via the Servers tab (DPAPI encrypted).
- Passwords stored via the Servers tab are encrypted with **Windows DPAPI
  (LocalMachine scope)** in `cfg.Servers.PasswordEnc`. The `rpt.Servers` view
  exposes only a `HasPassword BIT` — the encrypted blob never leaves the server.
- The dashboard HTTP server binds to `localhost` only. To share it with a team,
  front it with a reverse proxy that adds authentication (e.g. Nginx basic auth or
  IIS with Windows auth).

## Tuning
- Collection frequency: `@IntervalMinutes` in `agent\Create-AgentJobs.sql`.
- Forecast lookback & thresholds: params on `cfg.usp_Refresh_DiskForecast`.
- Cost z-score thresholds: `cfg.usp_Detect_CostAnomaly` (search for `@WarnZ`, `@CritZ`).
- Alert dedup window: `mon.AlertHistory` has a `LastRaisedAt` column — alerts
  re-fire only when a new condition fires *after* the last one resolved.
- History retention: `retentionDays` in the config (default 90).
