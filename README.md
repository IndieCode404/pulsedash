# DBADash — MSSQL &amp; Redshift monitoring dashboard

A one-stop DBA health desk for **SQL Server** and **Amazon Redshift**, built the
way a consultant would ship it: a central monitoring database, T-SQL collectors
fanned out through your **Central Management Server (CMS)**, PowerShell for the
Redshift side, a nightly forecast, and a zero-dependency dashboard on top.

It answers the questions clients actually ask:

1. **Are my Availability Groups healthy?** — AG sync state + health per database.
2. **How far behind is my data?** — AG redo lag (MSSQL) and ETL load freshness (Redshift), in one unified view.
3. **When do my disks fill up?** — least-squares growth forecast → *days to full* + a *"buy N GB"* recommendation.
4. **How fast are my databases/tables growing?** — per-database (MSSQL) and per-table (Redshift) size history on an SVG **growth chart** + a top-movers grid.
5. **Is my Redshift bill about to spike?** — in-cluster **cost-anomaly detection** (z-score vs. rolling baseline) on scan/Spectrum/storage drivers. See [docs/COST_ANOMALY.md](docs/COST_ANOMALY.md).
6. **Who do I call, and how do I get told?** — an app-owner directory you edit from a form, plus **email alerting** (Database Mail *or* SMTP) routed to the owner.
7. **Can I restore, and is my data intact?** — backup RPO health per database (full/diff/log ages vs. recovery model) + **last good DBCC CHECKDB**, offline/suspect database states, and Agent job failures.
8. **What's hurting right now?** — instance vitals (PLE, memory grants pending, blocked sessions), live **blocking chains** & long-running queries, top waits, and Redshift WLM queue depth, load errors, and **VACUUM/ANALYZE debt**.

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
| `sql\01`–`06` | Central DB: database, tables, forecast + purge procs, reporting views, owner CRUD |
| `sql\07`, `sql\11`, `sql\13` | Optional demo seeds (core → growth/cost/alerts → health/activity) |
| `sql\12_health.sql` | Proactive health: backups/CHECKDB, job failures, vitals, query snapshots, waits, Redshift table health (+ alert eval v2) |
| `sql\08_growth.sql` | DB/table size time-series + growth views |
| `sql\09_cost.sql` | Redshift cost-driver capture + z-score anomaly detection |
| `sql\10_alerts.sql` | Alert evaluation/dedup + Database Mail sender |
| `sql\03_collect_mssql.sql` | Target-side MSSQL collection queries (also runnable by hand in SSMS) |
| `redshift\redshift_metrics.sql` | Redshift disk, freshness, **table-size &amp; cost** queries (edit to fit your pipeline) |
| `deploy\Deploy-DBADash.ps1` | Builds/upgrades the central database |
| `deploy\Collect-All.ps1` | Scheduled collector: CMS fan-out + Redshift + forecast + cost + alert eval + purge |
| `deploy\Collect-Redshift.ps1` | Redshift ODBC collector (disk, freshness, sizes, cost) |
| `deploy\Send-Alerts.ps1` | Emails active alerts (SMTP or Database Mail) |
| `deploy\Common.ps1` | Shared helpers (no PowerShell module dependencies) |
| `deploy\config\dbadash.example.json` | Copy to `dbadash.json` and edit |
| `agent\Create-AgentJobs.sql` | Creates the SQL Agent schedule |
| `dashboard\Start-Dashboard.ps1` + `www\` | Self-contained HTML dashboard + JSON API (7 tabs) |
| `powerbi\`, `ssrs\` | Connect Power BI / SSRS to the same `rpt.*` views |
| `docs\COST_ANOMALY.md` | Redshift cost-anomaly playbook (AWS-native + in-cluster) |

---

## Setup (about 15 minutes)

### 0. Prerequisites
- A **central SQL Server** instance to host `DBADash` (Express is fine).
- A **CMS** with your MSSQL instances registered in a group (e.g. `PROD-SQL`).
  *No CMS? List instances in `mssqlInstances` in the config instead.*
- For Redshift: an **ODBC driver** on the collector box — *Amazon Redshift ODBC (x64)*
  (recommended) or *PostgreSQL Unicode(x64)*.
- The account running the collector needs **VIEW SERVER STATE** on every MSSQL
  target and **db_datawriter** on `DBADash`.

### 1. Configure
```powershell
cd K:\DBA_Monitoring\DBADash\deploy\config
copy dbadash.example.json dbadash.json
notepad dbadash.json    # set central instance, CMS group, Redshift cluster(s)
```
Tip: keep the Redshift password out of the file — set `$env:DBADASH_RS_PWD` instead.

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
You never write full connection strings; connections are assembled by the
collector. MSSQL targets are merged from **three sources**:

| How | Where | Auth |
|-----|-------|------|
| **CMS group** (best for fleets) | Register instances in SSMS → Central Management Servers → your group; set `cms.group` in the config | Windows auth |
| **Dashboard "Servers" tab** | Click *+ Add server* — writes to `cfg.Servers`, picked up next collection cycle | Windows auth |
| **Config list** (`cms.mssqlInstances`) | Strings for Windows auth, or objects for SQL auth: `{ "instance": "SQLDMZ01", "user": "dbadash_ro", "password": "", "passwordEnvVar": "DBADASH_DMZ_PWD" }` | Either |

Whatever the source, the collector account needs **VIEW SERVER STATE** +
**db_datareader on msdb** on each target.

**Redshift** clusters are defined only in the config's `redshift` array
(host/port/database/user — that *is* the connection info, used to build the
ODBC string; or set `dsn` to use a preconfigured DSN). The Servers tab can
register a cluster in inventory, but connectivity always comes from the config.

To pause a server, set it **Paused** on the Servers tab (sticks unless it's
still in the CMS group or config, which re-activate it); delete removes it
from inventory.

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

The dashboard has **9 tabs**: AG Sync, Data Lag, **Health** (backup RPO +
CHECKDB + job failures), **Activity** (vitals, blocking/long-running queries,
top waits, Redshift table maintenance), Disk Forecast, **Growth** (SVG chart +
top movers), **Cost** (per-metric trend chart + anomaly table), **Alerts**, and
App Owners.

**Proactive thresholds** (all tunable in `sql\12_health.sql` views):
- Backups — CRIT: db not ONLINE, no full backup in 7 days, or (FULL recovery) no
  log backup in 6 h; WARN: full > 2 days, log > 1 h, or CHECKDB > 30 days / never.
- Vitals — PLE < 300 s WARN / < 100 CRIT; memory grants pending > 0 WARN / ≥ 5 CRIT;
  blocked sessions > 0 WARN / ≥ 5 CRIT; Redshift queued queries or load errors > 0 WARN.
- Queries — any blocked session CRIT; runtime ≥ 10 min WARN.
- Redshift tables — unsorted or stats_off ≥ 20 % WARN / ≥ 50 % CRIT (run VACUUM/ANALYZE).

All of these also flow into `cfg.usp_Evaluate_Alerts`, so the email alerting
covers the full morning checklist (Backup / Job / Vitals / TableHealth categories).

### 6. (Optional) Turn on email alerts
In `dbadash.json` set `alerting.enabled = true` and pick a transport:
- **`smtp`** — `Send-Alerts.ps1` sends directly; just fill in `alerting.smtp`.
- **`dbmail`** — uses SQL Server Database Mail; set `alerting.dbmailProfile`
  (configure a Database Mail profile first) and it calls `cfg.usp_Send_Alert_Email`.

`Collect-All.ps1` evaluates alerts every run and, when enabled, sends any **new**
CRIT/WARN conditions (deduped so you're not re-spammed). Set `routeToOwners: true`
to also email the affected app's owner from `cfg.AppOwners`.

---

## How the pieces work

**AG sync & lag** come from `sys.dm_hadr_database_replica_states`. Lag is computed
as `DATEDIFF(second, secondary.last_commit_time, primary.last_commit_time)` per
database, so it's a true "seconds of data behind", not just queue size.

**Disk forecast** (`cfg.usp_Refresh_DiskForecast`) fits a least-squares line to
each volume's `UsedBytes` history over the last 30 days:
`slope = (nΣxy − ΣxΣy) / (nΣx² − (Σx)²)`. `DaysToFull = free / slope`, and
`RecommendedAddGB` sizes a new disk for ~180 days of headroom. Severity: **CRIT**
≤14 days, **WARN** ≤45 days.

**Redshift** disk comes from `stv_partitions`; load freshness from a best-effort
`stl_insert`/`stl_query` join — **edit `redshift\redshift_metrics.sql`** to match
how your pipeline lands data (or use `SYS_LOAD_HISTORY` on RA3/Serverless).

**Growth** is tracked in `mon.ObjectSize` — per-database for MSSQL (`sys.master_files`)
and per-table for Redshift (`svv_table_info`). The dashboard draws the series as a
dependency-free inline SVG line chart; `rpt.GrowthKeys` gives the top-movers grid
(current size + GB/day).

**Cost anomaly** (`cfg.usp_Detect_CostAnomaly`) keeps a 14-day rolling baseline per
Redshift cost driver (Spectrum TB scanned, bytes scanned, storage) and flags today
with a z-score: **WARN** at z≥2.5 or +50%, **CRIT** at z≥4 or +100%. This is the
same-day *leading indicator*; pair it with AWS Cost Anomaly Detection for invoice
truth — full playbook in [docs/COST_ANOMALY.md](docs/COST_ANOMALY.md).

**Alerts** (`cfg.usp_Evaluate_Alerts`) scan every `rpt.*` view, keep one active row
per problem in `mon.AlertHistory` (auto-resolving cleared ones), and feed the Alerts
tab + email. **App owners** live in `cfg.AppOwners`; the dashboard form calls
`cfg.usp_AppOwner_Upsert`, and Power BI / SSRS read the same table, so everything
stays in sync.

## Security notes
- Grant the collector a dedicated login with least privilege (VIEW SERVER STATE +
  db_datawriter on DBADash). It does **not** need sysadmin.
- Use a **Redshift read-only** user; never store its password in the JSON — use
  the `DBADASH_RS_PWD` env var or an ODBC DSN with saved credentials.
- The dashboard binds to `localhost` only. To expose it, front it with a reverse
  proxy that adds authentication.

## Tuning
- Collection frequency: `@IntervalMinutes` in `agent\Create-AgentJobs.sql`.
- Forecast thresholds / lookback: params on `cfg.usp_Refresh_DiskForecast`.
- History retention: `retentionDays` in the config (default 90).
