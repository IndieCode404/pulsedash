# Architecture — one engine, many faces

DBADash is **one engine with swappable faces**, not several dashboards. Read this
before adding a UI, a report, or an integration.

```
  COLLECTION + REPOSITORY  ─ the hard part, built once ─────────────┐
    deploy\ (PowerShell + dbatools collectors, via CMS)             │
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

- ✅ HTML dashboard (the primary face) → `SELECT * FROM rpt.Overview`, `rpt.EstateHealth`, …
- ✅ Power BI → same `rpt.*` views
- ✅ SSRS (optional) → same `rpt.*` views (see `ssrs\README.md`)
- ❌ A face that queries `mon.WaitStats` directly, or runs its own collector

## Where logic lives
- **Status / RAG / thresholds** → in the `rpt.*` SQL views (testable, reused by
  every face). Keep SSRS expressions and JS "dumb" — they render, they don't decide.
- **Collection** → `deploy\`. One place. New metric = new collector query + `mon.*`
  table + `rpt.*` view; every face picks it up for free.
- **Central procs** (`usp_Evaluate_Alerts`, `usp_Purge_History`, `rpt.Overview`)
  are re-defined by the highest-numbered `sql\NN` file — the last one wins. Add any
  new `mon.*` table to the newest purge.

## Why it's built this way
The value and the effort are in collection + the `rpt.*` contract. Faces are cheap
and swappable, so a client can be given SSRS (governance), the HTML console (modern),
Power BI (their standard), or an AI copilot — **all off the same engine, quoted as
one build.** That flexibility is the product, not four separate products.

## Do NOT
- Fork a face into its own repo/product with its own data model.
- Add an external dependency or any phone-home — the whole estate stays on one box
  (see the security posture in `README.md` / `fablesInstructions`).
