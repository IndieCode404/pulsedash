---
inclusion: always
---

# Tech & conventions

## Stack (do not add to it without a reason)
- **Windows Server + PowerShell 5.1** — collectors + the deploy/dashboard host.
- **SQL Server** (Express is fine) — the central repository.
- **Zero-dependency HTML/CSS/JS** — dashboard. No React/Vue/chart libraries; charts
  are inline SVG. The API is a PowerShell `HttpListener` (no IIS/Node in production).
- Target-side collection is **read-only T-SQL** against DMVs / `msdb`.

## Three layers — keep them separated
1. **Collect** — PowerShell + T-SQL DMV queries. Read-only. SQL-Server-specific by
   nature (you can't read SQL Server health without SQL Server DMVs). This layer is
   NOT expected to be portable.
2. **Store** — the central repository (schema, ingestion, reporting views). **THIS is
   the layer that must stay portable to Aurora PostgreSQL.**
3. **Present** — the dashboard reads only `rpt.*` views. Never the raw `mon.*` tables.

## Aurora PostgreSQL portability rules (the store layer)
The commitment is "migrate to Aurora PostgreSQL later without a challenge." Honour it:
- **Isolate the three engine-specific seams behind one helper each** (already done —
  keep it that way): connection-string building, bulk ingestion (`Write-BulkTable` /
  `SqlBulkCopy`), and the secret store (DPAPI). Swapping to Npgsql + `COPY` +
  a Postgres secret store must be a change in these helpers only.
- **Repository schema:** prefer portable types. Note the SQL Server → Postgres map in
  `docs/PORTABILITY.md` and update it whenever you add a table. Avoid `PERSISTED`
  computed columns and `SYSNAME` where avoidable; if used, log them in that file.
- **Reporting views (`rpt.*`) are the portability hotspot.** Prefer ANSI SQL:
  `COALESCE` not `ISNULL`, `FETCH … ONLY`/`LIMIT` not `TOP`, `string_agg` not
  `STUFF … FOR XML`, standard window functions, `CASE` not `IIF`. Where a
  SQL-Server-only construct is unavoidable, **isolate it and record it** in
  `docs/PORTABILITY.md` with its Postgres equivalent.
- **Keep stored procedures thin.** Business logic that lives in T-SQL procs must be
  re-translated for PL/pgSQL later. Keep procs to simple set operations; push real
  logic into the collector/app layer where it ports for free.
- **Every task that touches the store updates `docs/PORTABILITY.md`.** That file is
  the proof the migration won't be a surprise.

## Repository layout
- `sql/NN_*.sql` — numbered, ordered deploy scripts (run low→high; last wins for
  `CREATE OR ALTER`).
- `deploy/` — `Common.ps1` (shared helpers), `Deploy-DBADash.ps1`, `Collect-All.ps1`,
  `Collect-Redshift.ps1`, `Send-Alerts.ps1`, `Package-DBADash.ps1`, `Show-Targets.ps1`.
- `dashboard/` — `Start-Dashboard.ps1` + `www/` (HTML/CSS/JS).
- `docs/` — runbook, portability map, security checklist.

## Coding conventions
- Match the surrounding file's style and density.
- SQL: **always parameterised** — never string-concatenate values into a query.
- PowerShell: Windows PowerShell **5.1** — no `??`, no PS7-isms. Parse-check changes.
- HTML/JS: **escape every value** rendered into the page (see the security guardrails).
- Small, reviewable diffs. Prefer editing an existing file over creating a new one.
