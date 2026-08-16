# Foundation slice — design

## Shape (reuses the existing prototype)
```
 targets (non-prod SQL Server)          CLIENT NETWORK — no outbound calls
      │  read-only T-SQL (SELECT only)
      ▼
 deploy\Collect-All.ps1  ── Common.ps1 helpers ──►  central DB [DBADash]
      │                                               mon.*  snapshots (history)
      │                                               cfg.*  inventory + owners
      │                                               rpt.*  reporting views  ◄── the store/portability layer
      ▼
 dashboard\Start-Dashboard.ps1  ──►  www\  (localhost only, escaped output)
```

## Components
- **Central DB** — `sql/01`–`02` (database + core tables), plus the forecast +
  purge procs. Types chosen for portability; see `docs/PORTABILITY.md`.
- **Ingestion helper** — `Common.ps1 → Write-BulkTable`. The ONE place `SqlBulkCopy`
  is used. Maps source columns to destination by name, case-insensitively. To port:
  swap this function for Npgsql `COPY`; nothing else changes.
- **Connection helper** — `Common.ps1 → Get-SqlConnString` (built via
  `SqlConnectionStringBuilder`, indexer form). The ONE place a connection string is
  assembled. To port: a Postgres variant here.
- **Secret store** — DPAPI in `Common.ps1`. The ONE place secrets are encrypted. To
  port: a Postgres-side secret store here.
- **Collectors** — target-side T-SQL held as here-strings in `Collect-All.ps1`; each
  result bulk-loaded via the helper. Read-only; SQL-Server-specific by design.
- **Reporting views** — `rpt.BackupHealth`, `rpt.DiskForecast`, `rpt.JobFailures`,
  `rpt.Overview`, plus the estate rollup. ANSI-leaning; the portability hotspot.
- **Dashboard** — static `www/` + a PowerShell `HttpListener` JSON API reading
  `rpt.*`. `esc()` on every rendered value; CSRF header; path containment; localhost.

## Portability seam (the whole Aurora story)
Only three functions are engine-specific — `Get-SqlConnString`, `Write-BulkTable`,
and the DPAPI pair. Keep them the only SQL-Server-coupled code in the store layer.
The reporting views must translate cleanly (COALESCE/LIMIT/string_agg/window fns).
`docs/PORTABILITY.md` is the running ledger of anything that isn't already portable.

## Failure isolation
Each target is wrapped in its own try/catch; a failure logs an ERROR row in
`cfg.CollectionLog` and the run continues. Redshift (out of scope this slice) is
similarly isolated so it can never abort SQL collection.

## Data model (core tables — portable types)
`cfg.Servers` (inventory), `cfg.AppOwners`, `cfg.CollectionLog`,
`mon.BackupStatus`, `mon.DiskUsage`, `mon.JobFailure`, `mon.DiskForecast`.
Append-only snapshots keyed by `CollectedAt` + `ServerName`; `rpt.*` views expose the
latest per key and compute status. See `docs/PORTABILITY.md` for the type map.

## Non-goals (this slice)
No Redshift, no AI, no auth beyond localhost, no alerting beyond the existing email
path. Keep them out.
