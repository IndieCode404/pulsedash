# Architecture — one engine, many faces

DBADash is **one engine with swappable faces**, not several dashboards. Read this
before adding a UI, a report, or an integration.

```
  COLLECTION + REPOSITORY  ─ the hard part, built once ─────────────┐
    deploy\ (PowerShell collectors, per-engine)                     │
    sql\    (central DBADash DB: mon.* time-series, cfg.* inventory)│  = DBADash
    sql\    (rpt.* reporting views)  ◄── THE CONTRACT               │
                         │                                          │
                         ▼                                          │
   ┌───────────────┬───────────────┬───────────────┬───────────────┤
   │ dashboard\www │   powerbi\    │    ssrs\       │  (AI copilot) │  ← faces
   │ HTML console  │    PBIX       │  optional      │   future      │
   │  (primary)    │               │                │               │
   └───────────────┴───────────────┴───────────────┴───────────────┘
```

## The one rule
**Every face reads only `rpt.*`. Never the raw `mon.*` tables, never its own
collection.** The `rpt.*` views are the stable contract between the engine and the
presentation. Obey this and all faces stay in sync automatically; break it and you
get drift and duplicated logic.

- OK: HTML dashboard → `SELECT * FROM rpt.Overview`, `rpt.EstateHealth`, ...
- OK: Power BI → same `rpt.*` views
- OK: SSRS (optional) → same `rpt.*` views (see `ssrs\README.md`)
- NOT OK: A face that queries `mon.WaitStats` directly, or runs its own collector

## Where logic lives
- **Status / RAG / thresholds** → in the `rpt.*` SQL views (testable, reused by
  every face). Keep SSRS expressions and JS "dumb" — they render, they don't decide.
- **Collection** → `deploy\`. One place per engine. New metric = new collector query +
  `mon.*` table + `rpt.*` view; every face picks it up for free.
- **Central procs** (`usp_Evaluate_Alerts`, `usp_Purge_History`, `rpt.Overview`)
  are re-defined by the highest-numbered `sql\NN` file — the last one wins. Add any
  new `mon.*` table to the newest purge.

## Multi-engine design (built to extend)

The architecture separates **engine-specific** code (collectors) from
**engine-agnostic** code (central schema, dashboard, alerting). This means:

```
  ┌─────────────────────────────────────────────┐
  │  Engine-specific (one per database type)      │
  │  ✓ Collect-All.ps1      (MSSQL via T-SQL)    │
  │  ✓ Collect-Redshift.ps1 (Redshift via ODBC)  │
  │  ○ Collect-Oracle.ps1   (future, ODP.NET)    │
  │  ○ Collect-Aurora.ps1   (future, Npgsql)     │
  │  ○ Collect-Db2.ps1      (future, ODBC)       │
  │  ○ Collect-Couchbase.ps1(future, REST API)   │
  └──────────────────┬──────────────────────────┘
                     │ Write-BulkTable (Common.ps1)
                     ▼
  ┌──────────────────────────────────────────────┐
  │  Engine-agnostic (shared)                     │
  │  mon.* tables: keyed by ServerName+CollectedAt│
  │  cfg.Servers: Platform column identifies type │
  │  rpt.* views: latest-per-key, filterable      │
  │  Estate grid: works across all platforms       │
  │  Alert engine: evaluates all rpt.* views       │
  │  Dashboard: shows all engines on one screen    │
  └──────────────────────────────────────────────┘
```

**Adding Oracle, Aurora, Db2, or Couchbase** is a new `Collect-*.ps1` that writes
into the same `mon.*` tables using normalized metric shapes. The central schema,
dashboard, and alerting work unchanged.

Eight **universal health metrics** normalize across all engines: storage usage,
replication lag, backup recency, active sessions, instance vitals, failed logins,
object sizes, and collection status. These power the estate grid, forecasts,
growth charts, health view, and alerting for any engine with zero UI changes.

See [docs/EVOLUTION.md](docs/EVOLUTION.md) for the full roadmap and per-engine
source mapping.

## Why it's built this way
The value and the effort are in collection + the `rpt.*` contract. Faces are cheap
and swappable, so a client can be given SSRS (governance), the HTML console (modern),
Power BI (their standard), or an AI copilot — **all off the same engine, quoted as
one build.** That flexibility is the product, not four separate products.

## Do NOT
- Fork a face into its own repo/product with its own data model.
- Add an external dependency or any phone-home — the whole estate stays on one box
  (see the security posture in `README.md`).
- Build engine-specific logic into the dashboard — it reads `rpt.*` views, which
  handle engine differences internally.
