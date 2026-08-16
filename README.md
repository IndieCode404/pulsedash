# DBADash — MSSQL & Redshift monitoring dashboard (Phase 1 POC)

A one-stop DBA health desk for **SQL Server** and **Amazon Redshift**, built the
way a consultant would ship it: a central monitoring database, T-SQL collectors
fanned out through your **Central Management Server (CMS)**, PowerShell for the
Redshift side, a nightly forecast, a zero-dependency HTML dashboard, and alert
evaluation that feeds email routing to your app owners.

**Designed for evolution:** the architecture separates collection (engine-specific)
from storage and presentation (engine-agnostic), so adding Oracle, Aurora
PostgreSQL, Db2, or Couchbase later is a new collector plugin — not a rewrite.
See [ARCHITECTURE.md](ARCHITECTURE.md) and [docs/EVOLUTION.md](docs/EVOLUTION.md).

It answers the questions clients actually ask on day one:

1. **Are my Availability Groups healthy?** — AG sync state + health per database.
2. **How far behind is my data?** — AG redo lag (MSSQL) and ETL load freshness (Redshift), in one unified view.
3. **When do my disks fill up?** — least-squares growth forecast → *days to full* + a *"buy N GB"* recommendation.
4. **How fast are my databases/tables growing?** — per-database (MSSQL) and per-table (Redshift) size history on an SVG **growth chart** + a top-movers grid.
5. **Who do I call, and how do I get told?** — an app-owner directory you edit from a form, plus alert evaluation that routes to the owner.
6. **Can I restore, and is my data intact?** — backup RPO health per database (full/diff/log ages vs. recovery model), **last good DBCC CHECKDB**, offline/suspect database states, and Agent job failures.
7. **What's hurting right now?** — instance vitals (PLE, memory grants pending, blocked sessions, deadlocks), live **blocking chains** & long-running queries, top waits, top queries by CPU, and Redshift WLM queue depth, load errors, and **VACUUM/ANALYZE debt**.
8. **Who is on my server and who keeps failing to log in?** — failed-login audit (MSSQL error log + Redshift connection log) and a live session inventory showing host, app, login, and duration.

Runs on **SQL Server + PowerShell only**. No Node, no IIS, no licenses.

> **One engine, many faces.** DBADash is the collection engine + `rpt.*` view
> contract; the **HTML dashboard** (primary), Power BI, and optional SSRS are
> swappable presentations of the same data — see [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Architecture

```
   ┌──────────── Monitored fleet ────────────┐
   │  MSSQL (AGs + standalone)   Redshift     │
   │  (future: Oracle, Aurora, Db2, Couch)    │
   └──────┬───────────────────────┬───────────┘
          │ CMS fan-out (T-SQL)   │ ODBC (PowerShell)
          ▼                       ▼
   deploy\Collect-All.ps1  →  deploy\Collect-Redshift.ps1
          │                       │
          └──────────┬────────────┘
                     ▼
        ┌──────────────────────────┐
        │  DBADash  (central DB)    │
        │  mon.*  time-series       │  ← engine-agnostic schema
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
| `sql/01_create_database.sql` | Creates the DBADash DB with mon/cfg/rpt schemas |
| `sql/02_tables.sql` | Core tables: Servers, AGSyncStatus, DataLag, DiskUsage, DiskForecast, AppOwners, CollectionLog |
| `sql/04_procs_forecast.sql` | Disk forecast (least-squares) + purge stored procedures |
| `sql/05_views_dashboard.sql` | Core `rpt.*` views consumed by dashboard + Power BI |
| `sql/06_appowners_crud.sql` | App owner CRUD procs |
| `sql/08_growth.sql` | DB/table size time-series (`mon.ObjectSize`) + `rpt.GrowthKeys` view |
| `sql/10_alerts.sql` | Alert evaluation/dedup (`mon.AlertHistory`, `usp_Evaluate_Alerts`) |
| `sql/12_health.sql` | Proactive health: backups/CHECKDB, job failures, vitals, waits (alert eval v2, purge) |
| `sql/14_servers_admin.sql` | Server admin procs, `rpt.Servers` (last collection status) |
| `sql/15_perf_logins.sql` | Top queries by CPU, failed-login audit, session inventory |
| `sql/16_connections.sql` | Connection fields on `cfg.Servers`: Host, Port, AuthType, DPAPI blob |
| `sql/21_estate.sql` | Estate health grid (6 domains: Backup, Disk, Jobs, HA, Perf, Data) |
| `sql/07_seed_demo.sql` | Optional demo data |
| `redshift/redshift_metrics.sql` | Redshift SQL blocks: DISK, FRESHNESS, TABLE_SIZE, TABLE_HEALTH, ACTIVITY, RS_VITALS, RS_LOGINS |
| `deploy/Deploy-DBADash.ps1` | Builds / upgrades the central database |
| `deploy/Collect-All.ps1` | Main collector: CMS fan-out, forecast refresh, alert eval, purge |
| `deploy/Collect-Redshift.ps1` | Redshift ODBC collector |
| `deploy/Common.ps1` | Shared helpers: config loader, SQL helpers, DPAPI encrypt/decrypt |
| `deploy/config/dbadash.example.json` | Copy to `dbadash.json`, edit with your instance details |
| `agent/Create-AgentJobs.sql` | Creates the "DBADash - Collect" SQL Agent job |
| `dashboard/Start-Dashboard.ps1` + `www/` | Self-contained PowerShell HTTP server + HTML/CSS/JS dashboard (10 tabs) |
| `powerbi/`, `ssrs/` | Connect Power BI / SSRS to the same `rpt.*` views |

---

## Setup (about 15 minutes)

### 0. Prerequisites
- A **central SQL Server** instance to host `DBADash` (Express is fine).
- A **CMS** with your MSSQL instances registered in a group.
  *No CMS? List instances in `mssqlInstances` in the config, or add them
  via the dashboard Servers tab.*
- For Redshift: an **ODBC driver** on the collector box.
- Collector account: **VIEW SERVER STATE** + **db_datareader on msdb** on targets,
  **db_datawriter** on `DBADash`.

### 1. Build the central database
```powershell
cd deploy
.\Deploy-DBADash.ps1                  # asks for the instance + auth on first run
.\Deploy-DBADash.ps1 -WithDemoData    # OR: also load demo data
```

### 2. (Optional) Finish the config
Edit `deploy\config\dbadash.json` to add your CMS group and Redshift clusters.

### 3. Run a collection
```powershell
.\Collect-All.ps1
```
Check `SELECT * FROM DBADash.cfg.CollectionLog ORDER BY RunAt DESC;`

### 4. Schedule it
Open `agent\Create-AgentJobs.sql` in SSMS, set `@ScriptPath` / `@IntervalMinutes`, run.

### 5. Open the dashboard
```powershell
cd ..\dashboard
.\Start-Dashboard.ps1
# browse to http://localhost:8080
```

| Tab | What you see |
|-----|-------------|
| **Estate** | Every server × 6 domains (Backup, Disk, Jobs, HA, Perf, Data), worst-first |
| **AG Sync** | AG sync state, health per database |
| **Data Lag** | AG redo lag + Redshift load freshness |
| **Health** | Backup RPO, CHECKDB age, job failures, failed logins, session inventory |
| **Activity** | Vitals, blocking, top waits, Redshift maintenance, top queries by CPU |
| **Disk Forecast** | Days-to-full + "buy N GB" sizing |
| **Growth** | SVG trend chart + top-movers grid |
| **Alerts** | Active CRIT/WARN conditions |
| **App Owners** | Editable app-owner directory |
| **Servers** | Server inventory + connection form |

---

## Runs entirely on one box — nothing leaves the client

- **What it needs:** SQL Server (Express ok), PowerShell 5.1, optional ODBC driver.
- **Where the data lives:** the `DBADash` database on that server. Passwords DPAPI-encrypted.
- **What crosses the wire:** only the collector reading metrics (read-only). **No telemetry.**

## Security notes
See `docs/SECURITY-CHECKLIST.md` for the full gate. Headlines:
- Parameterized SQL, `esc()` on all HTML output, CSRF header, localhost binding.
- DPAPI (LocalMachine) for stored passwords. Treat the box like a jump host.
- `TrustServerCertificate=True` — encrypted but not CA-validated.

## Future: multi-engine monitoring
The architecture is designed to extend beyond MSSQL and Redshift. See
[docs/EVOLUTION.md](docs/EVOLUTION.md) for the roadmap covering Oracle, Aurora
PostgreSQL, Db2, and Couchbase. The key: each engine gets its own collector,
but the central schema, dashboard, and alerting are engine-agnostic.

## Kiro / AI-assisted development
See `KIRO-AUTOMODEL.md` for the complete instruction set, pitfalls, and recipes.
See `docs/KIRO-KICKOFF.md` for the first-time kickoff prompt.
