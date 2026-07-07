# Power BI on top of DBADash

The HTML dashboard is the turnkey option. If your shop standardizes on Power BI,
point it at the same `rpt.*` views — no extra modeling required.

## Connect
1. **Get Data → SQL Server** → Server `SQLMON01`, Database `DBADash`.
2. Choose **Import** (for scheduled refresh) or **DirectQuery** (for near-live).
3. Select these views:
   - `rpt.Overview`
   - `rpt.AGSyncStatus`
   - `rpt.DataLag`
   - `rpt.DiskForecast`
   - `rpt.AppOwners`

## Suggested pages
| Page | Visual | Source |
|------|--------|--------|
| Health header | Card visuals | `rpt.Overview` (AGUnhealthy, DisksCrit, LagObjectsCrit) |
| AG Sync | Table + conditional format on `Status` | `rpt.AGSyncStatus` |
| Data Lag | Bar chart of `LagSeconds` by `ObjectName`, sliced by `Platform` | `rpt.DataLag` |
| Disk Forecast | Table with data bars on `UsedPct`; KPI on `DaysToFull` | `rpt.DiskForecast` |
| App Owners | Table (read-only directory) | `rpt.AppOwners` |

## A couple of handy DAX measures
```DAX
Disks At Risk = CALCULATE(COUNTROWS('rpt DiskForecast'), 'rpt DiskForecast'[Severity] <> "OK")

Worst Lag (min) = DIVIDE(MAX('rpt DataLag'[LagSeconds]), 60)

AG Health % =
DIVIDE(
    CALCULATE(COUNTROWS('rpt AGSyncStatus'), 'rpt AGSyncStatus'[Status] = "OK"),
    COUNTROWS('rpt AGSyncStatus')
)
```

## Conditional formatting rule (reuse everywhere)
Background color by field value on `Status` / `Severity`:
`OK` → green, `WARN` → amber, `CRIT` → red.

## Refresh & editing owners
Power BI is read-only. To **edit** app-owner records, either keep the HTML
dashboard's owner tab open alongside, or (Import mode) set a Gateway + scheduled
refresh so owner edits made in the HTML form flow into the report on next refresh.
