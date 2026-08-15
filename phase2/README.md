# Phase 2 — Advanced Modules

These files were separated from the Phase 1 (POC) codebase to keep the initial
deployment clean and focused. Once the POC is approved, merge them back by
running the SQL scripts, restoring the collector queries, and re-enabling the
dashboard tabs.

## What's here

| Folder | Files | Purpose |
|--------|-------|---------|
| `sql/` | `09_cost.sql` | Redshift cost tables, anomaly detection proc, cost views |
| | `11_seed_growth_cost.sql` | Demo seed for growth + cost data |
| | `13_seed_health.sql` | Demo seed for health/audit data |
| | `15_perf_audit_cost.sql` | Stale tables, Spectrum scans (Phase 1 parts extracted to `sql/15_perf_logins.sql`) |
| | `17_advisor.sql` | Advisor/findings: lock-wait analysis, root-cause + prevention |
| | `18_server_audit.sql` | Server info, config drift, access control, index health |
| | `19_bottlenecks.sql` | File I/O latency, wait deltas, autogrowth events |
| | `20_query_cost.sql` | Per-query cost attribution (Redshift Spectrum) |
| `deploy/` | `Send-Alerts.ps1` | SMTP-based alert email sender |
| `docs/` | `COST_ANOMALY.md` | Cost anomaly detection design doc |

## How to merge back

1. Copy the `phase2/sql/*.sql` files back to `sql/`.
2. Add them to the `$scripts` array in `deploy/Deploy-DBADash.ps1`.
3. Re-run `Deploy-DBADash.ps1` to create the Phase 2 tables and procs.
4. Restore the Phase 2 collector queries in `deploy/Collect-All.ps1` and
   `deploy/Collect-Redshift.ps1` (the queries are preserved in git history).
5. Re-enable the dashboard tabs in `dashboard/www/index.html` and the loader
   functions in `dashboard/www/app.js`.
6. Copy `Send-Alerts.ps1` back to `deploy/`.

The git history preserves every version of these files, so nothing is lost.
