# Getting started in Kiro (client machine)

This project ships with Kiro **steering** (`.kiro/steering/`) and a first **spec**
(`.kiro/specs/foundation/`). Steering files are injected into every request, so the
model always has the guardrails — you don't have to repeat them.

## Phase 1 / Phase 2 split

The codebase is split into two scopes:

- **Phase 1 (root)** — the approved POC scope. Everything at root (`sql/`, `deploy/`,
  `dashboard/`) is clean, self-contained, and ready to deploy. This is what ships to
  the client machine.
- **Phase 2 (`phase2/`)** — advanced modules parked for later. Advisor, bottlenecks,
  cost anomaly, access control, config audit, index health, Spectrum. See
  `phase2/README.md` for the full list and merge-back steps.

**Do not reference Phase 2 code from Phase 1 files.** When the POC is approved, Phase 2
files merge back — until then, keep the scopes separate.

## 1. Set up
1. Open this project folder in Kiro on the client machine.
2. Confirm Kiro sees the steering files (`.kiro/steering/product.md`, `tech.md`,
   `guardrails.md`) and the spec under `.kiro/specs/foundation/`.
3. Put **no client specifics** in these files — use placeholders. Real instance
   names / credentials live only in `deploy/config/dbadash.json`, which is
   git-ignored and must never be pasted into the assistant.

## 2. Keep API spend low (it's metered and monitored)
- **Reuse the existing code. Never ask it to "rebuild" or "regenerate" a file that
  exists** — ask for a specific edit.
- Work **one spec task at a time** (open `tasks.md`, do task N, review, commit).
- Use the **cheapest model that fits**; escalate only for hard reasoning, then drop
  back.
- **Turn off agent hooks that run on save** (or any auto-run automation) during the
  POC — they re-invoke the model on every change and quietly rack up spend.
- Keep context tight: rely on steering + the open file, not repo-wide scans.
- If a task balloons (many files, repeated retries), **stop and checkpoint** — that's
  usually a sign the ask was too big, not that it needs more tokens.

## 3. Kickoff prompt (paste as your first message in Kiro)

```
You are working inside the DBADash repository — a SQL-native DBA monitoring
platform for MSSQL and Redshift. Read the Kiro steering files in
`.kiro/steering/` — treat `guardrails.md` as hard constraints that override
everything else.

IMPORTANT CONTEXT:
- A working Phase 1 prototype already exists in this repo. DO NOT regenerate
  or rebuild files — make small, targeted edits to what exists.
- The codebase is split: Phase 1 (root) = approved POC scope; Phase 2
  (`phase2/`) = advanced modules parked for later. Do not mix them.
- Phase 1 covers: estate grid, backup/RPO/CHECKDB, disk forecast, AG sync,
  basic performance (vitals/waits/blocking/top queries), agent jobs, failed
  logins, data lag, Redshift essentials (storage/freshness/vacuum), growth
  tracking, alerts, app owners, server inventory.
- The central store must stay portable to AWS Aurora PostgreSQL (see
  `docs/PORTABILITY.md` for the type/function ledger).
- The HTML dashboard must not introduce vulnerabilities (see
  `docs/SECURITY-CHECKLIST.md`).

HARD RULES — confirm you understand before writing ANY code:
1. Nothing leaves the client network. No client data in prompts.
2. Monitored targets are READ-ONLY — SELECT only. Writes go to central DB.
3. Stay on approved non-prod instances only.
4. Work one task at a time. Keep diffs small. Control API spend.
5. Windows PowerShell 5.1 only — no `??`, no PS7-isms.
6. Zero external dependencies — no npm/CDN/React in production.

KEY FILES TO KNOW:
- deploy/Common.ps1 — shared helpers (Get-SqlConnString uses INDEXER form
  `$b['Data Source']`, NOT property syntax; Write-BulkTable does
  case-insensitive column mapping; DPAPI secret helpers)
- deploy/Deploy-DBADash.ps1 — creates the central database
- deploy/Collect-All.ps1 — the collector (runs per SQL Agent schedule)
- deploy/Show-Targets.ps1 — dry-run: shows what servers would be contacted
- dashboard/Start-Dashboard.ps1 — the production dashboard (HttpListener)
- dashboard/demo-server.js — Node mock server for preview (port 8099)

KNOWN PITFALLS (already fixed, don't re-introduce):
- SqlConnectionStringBuilder: use `$b['Data Source']` not `$b.DataSource`
  (PS 5.1 indexer vs. property throws "Keyword not supported: DataSource")
- Redshift ODBC driver: cast with `[string]$driver` (PSObject→String crash)
- SqlBulkCopy column mapping is case-sensitive; Write-BulkTable handles it
- Version-gated DMVs (dm_os_host_info 2017+, dm_db_log_info 2016 SP2+)
  must be wrapped in TRY/CATCH dynamic SQL
- HttpListener: use GetContextAsync() + wait loop so Ctrl+C works
- ISNULL(..., 0) on nullable vitals going into NOT NULL columns

Start with task 1 in `.kiro/specs/foundation/tasks.md`: confirm the central
database deploys to the non-prod instance and creates only `[DBADash]`. Tell
me the exact commands to run, wait for my output, then proceed. Do not run
ahead to later tasks.
```

## 4. Workflow
`spec → pick the next unchecked task → smallest edit → you run it → paste result →
model verifies → commit`. Update `tasks.md` checkboxes and `docs/PORTABILITY.md` as
you go. Deploy/collect commands and their checks are in the main `README.md`.

## 5. When you hit an error
Paste the **error text** (with any client-identifying values redacted) or the
`cfg.CollectionLog` message. Fixes so far have been 1–2 lines — ask for the specific
change, not a rewrite.
