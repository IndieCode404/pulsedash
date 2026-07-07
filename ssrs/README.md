# SSRS on top of DBADash

For a SQL-Server-native, paginated / emailable report, build SSRS reports
against the same `rpt.*` views. This suits scheduled PDF snapshots to management.

## Data source
Shared data source `DBADash`:
```
Data Source=SQLMON01;Initial Catalog=DBADash;Integrated Security=SSPI
```

## Suggested reports (one .rdl each)
| Report | Dataset query | Notes |
|--------|---------------|-------|
| `AG_Sync.rdl`      | `SELECT * FROM rpt.AGSyncStatus ORDER BY Status DESC` | Color the Status cell by value |
| `Data_Lag.rdl`     | `SELECT * FROM rpt.DataLag ORDER BY LagSeconds DESC`  | Group by Platform |
| `Disk_Forecast.rdl`| `SELECT * FROM rpt.DiskForecast ORDER BY DaysToFull`  | Data bar on UsedPct; highlight Severity |
| `App_Owners.rdl`   | `SELECT * FROM rpt.AppOwners ORDER BY Criticality`    | Contact directory |
| `Health_Summary.rdl` | `SELECT * FROM rpt.Overview`                        | Single-row KPI banner; use as subscription cover page |

## Status coloring expression (Text Box → Color)
```
=Switch(
    Fields!Status.Value = "CRIT", "Firebrick",
    Fields!Status.Value = "WARN", "DarkOrange",
    True, "ForestGreen")
```

## Subscriptions
Add a **data-driven subscription** on `Health_Summary.rdl` to email the on-call
DBA every morning at 07:00. Pull recipient addresses straight from
`rpt.AppOwners` (Email column) for per-app routing.

## Editing owners
SSRS is read-only. Keep the HTML dashboard for owner edits — both read/write the
same `cfg.AppOwners` table, so they stay perfectly in sync.
