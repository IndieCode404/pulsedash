# Evolution — multi-engine monitoring roadmap

> **This is a design document, not a backlog.** It captures the architectural
> thinking so the POC can evolve into a multi-engine monitoring platform without
> a rewrite. Nothing here is built yet — it exists so future work has a
> well-understood path.

---

## The extensibility model

DBADash already separates three layers:

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  COLLECT (engine-specific)                                       │
  │  Each engine has its own collector script + native queries.       │
  │  They write into the SAME central schema using Common.ps1.       │
  │                                                                  │
  │  Today:  Collect-All.ps1 (MSSQL)                                 │
  │          Collect-Redshift.ps1 (Redshift via ODBC)                │
  │                                                                  │
  │  Future: Collect-Oracle.ps1                                      │
  │          Collect-Aurora.ps1                                       │
  │          Collect-Db2.ps1                                          │
  │          Collect-Couchbase.ps1                                    │
  └──────────────────────────┬───────────────────────────────────────┘
                             │ Write-BulkTable (Common.ps1)
                             ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  STORE (engine-agnostic central schema)                          │
  │  mon.* tables hold metrics from ALL engines.                     │
  │  cfg.Servers identifies each target by Platform.                 │
  │  rpt.* views expose the latest per-key, filterable by Platform.  │
  │                                                                  │
  │  Key: metrics are NORMALIZED to a common shape.                  │
  │  "Disk free %" means the same thing whether the source is        │
  │  MSSQL sys.dm_os_volume_stats or Oracle DBA_FREE_SPACE.          │
  └──────────────────────────┬───────────────────────────────────────┘
                             │ rpt.* views
                             ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │  PRESENT (engine-aware, not engine-specific)                     │
  │  Dashboard shows all engines on one Estate grid.                 │
  │  Filters by Platform column when drilled in.                     │
  │  Engine-specific tabs (AG Sync = MSSQL only) are visible only    │
  │  when that engine exists in cfg.Servers.                         │
  └──────────────────────────────────────────────────────────────────┘
```

**Adding a new engine is adding a new collector** — not touching the store or
the dashboard (except to show engine-specific drill-ins).

---

## What already exists for multi-engine

| Capability | Current state | Why it matters |
|-----------|--------------|----------------|
| `cfg.Servers.Platform` column | `MSSQL` / `Redshift` | New engine = new platform value |
| `mon.*` tables keyed by `ServerName` | Works for any engine | Oracle RAC → use `instance_name@host` |
| `rpt.*` views filter by latest snapshot | Engine-agnostic pattern | New engine data appears automatically |
| `cfg.CollectionLog` | Logs per-server per-run | New collector logs into the same table |
| Estate grid (`sql/21`) | Domains: Backup, Disk, Jobs, HA, Perf, Data | Engine-specific rules per domain |
| `Common.ps1` helpers | Connection, bulk-load, secrets | Per-engine connection builders needed |
| Dashboard `Platform` badge | Shows on Servers tab | Filter estate/tabs by platform |

---

## Per-engine collector design

Each engine gets its own `Collect-<Engine>.ps1` that follows the same pattern:

```
1. Read targets from cfg.Servers WHERE Platform = '<Engine>'
2. For each target:
   a. Connect using engine-native driver
   b. Run health queries (engine-specific SQL / API)
   c. Normalize results to mon.* schema shapes
   d. Write via Write-BulkTable (or an engine-specific bulk helper)
   e. Log to cfg.CollectionLog
3. Post-processing (forecast, alerts) runs once after ALL collectors
```

### Oracle
| What to monitor | Source | Normalizes to |
|----------------|--------|---------------|
| Tablespace usage | `DBA_TABLESPACE_USAGE_METRICS` | `mon.DiskUsage` (Volume → Tablespace) |
| Backup status | `V$RMAN_BACKUP_JOB_DETAILS` | `mon.BackupStatus` (BackupType, AgeMins) |
| Data Guard lag | `V$DATAGUARD_STATS` | `mon.DataLag` (LagSeconds) |
| Instance vitals | `V$SYSSTAT`, `V$SYSTEM_EVENT` | `mon.InstanceVitals` (CPU, buffer cache hit, waits) |
| Blocking sessions | `V$SESSION` (blocking_session) | `mon.ActivitySnapshot` |
| ASM disk groups | `V$ASM_DISKGROUP` | `mon.DiskUsage` |
| Alert log errors | `X$DBGALERTEXT` or external table | `mon.FailedLogin` / new `mon.OracleAlertLog` |

**Connection:** Oracle Instant Client + PowerShell `ODP.NET` (managed) or `System.Data.OracleClient`.
Add `Get-OracleConnString` to `Common.ps1` alongside `Get-SqlConnString`.

**RAC consideration:** each instance in a RAC cluster is a separate ServerName
(e.g. `PRODRAC1`, `PRODRAC2`); the cluster is a tag in `cfg.Servers.FriendlyName`.

### Aurora PostgreSQL
| What to monitor | Source | Normalizes to |
|----------------|--------|---------------|
| Database sizes | `pg_database_size()` | `mon.ObjectSize` |
| Replication lag | `pg_stat_replication` | `mon.DataLag` |
| Connection stats | `pg_stat_activity` | `mon.ActivitySnapshot` |
| Long queries | `pg_stat_activity` (state = 'active', duration > X) | `mon.ActivitySnapshot` |
| Vacuum status | `pg_stat_user_tables` (last_autovacuum) | `mon.TableHealth` |
| Disk usage | `pg_tablespace_size()` + CloudWatch RDS metrics | `mon.DiskUsage` |
| Failed logins | CloudWatch Logs (pgaudit) or `log_connections` | `mon.FailedLogin` |

**Connection:** Npgsql PowerShell module or `System.Data.Odbc` with PostgreSQL ODBC driver.
Aurora-specific: read replica lag via `aurora_replica_status()`.

### Db2
| What to monitor | Source | Normalizes to |
|----------------|--------|---------------|
| Tablespace usage | `SYSIBMADM.TBSP_UTILIZATION` | `mon.DiskUsage` |
| Backup history | `SYSIBMADM.DB_HISTORY` | `mon.BackupStatus` |
| HADR status | `MON_GET_HADR()` | `mon.DataLag` |
| Lock waits | `MON_GET_APPL_LOCKWAIT()` | `mon.ActivitySnapshot` |
| Instance vitals | `MON_GET_DATABASE()` | `mon.InstanceVitals` |
| Diagnostic log | `SYSIBMADM.PDLOGMSGS_LAST24HOURS` | `mon.FailedLogin` + alerting |

**Connection:** IBM Data Server Driver + `System.Data.Odbc` or IBM's .NET provider.

### Couchbase
| What to monitor | Source | Normalizes to |
|----------------|--------|---------------|
| Bucket storage | REST API `/pools/default/buckets` | `mon.DiskUsage` (bucket = volume) |
| XDCR lag | REST API `/pools/default/remoteClusters` | `mon.DataLag` |
| Node health | REST API `/pools/default` | `mon.InstanceVitals` |
| Slow queries | N1QL `system:completed_requests` | `mon.ActivitySnapshot` |
| Failed logins | Audit log (`/settings/audit`) | `mon.FailedLogin` |
| Index status | REST API `/indexStatus` | future `mon.IndexHealth` |

**Connection:** REST API (PowerShell `Invoke-RestMethod` — localhost or internal only,
never external). Couchbase has no SQL driver; the collector is API-driven.

**Important:** Couchbase REST API calls stay within the client network. The
monitoring box must be able to reach the Couchbase cluster's management port (8091).

---

## Schema evolution for multi-engine

### What stays the same
The existing `mon.*` tables already work for multiple engines because they're keyed
by `ServerName` + `CollectedAt`. The `Platform` column in `cfg.Servers` identifies
the engine. Most tables need NO schema change:

- `mon.DiskUsage` — Oracle tablespaces and Couchbase buckets map to "volumes"
- `mon.BackupStatus` — Oracle RMAN and Db2 backup history fit the same shape
- `mon.DataLag` — Data Guard, HADR, XDCR all reduce to "seconds behind"
- `mon.InstanceVitals` — each engine's key metrics normalize to the same structure
- `mon.ActivitySnapshot` — blocking/long queries exist in every engine
- `mon.FailedLogin` — failed auth exists everywhere
- `mon.ObjectSize` — database/table sizes exist everywhere

### What needs extending
| Need | Approach |
|------|----------|
| Engine-specific health checks | New `rpt.*` views filtered by Platform (e.g. `rpt.OracleTablespaces`) |
| Engine-specific tabs | Dashboard: show/hide tabs based on which Platforms exist in cfg.Servers |
| Connection helpers per engine | Add `Get-OracleConnString`, `Get-PgConnString`, etc. to Common.ps1 |
| Bulk-load per engine | `Write-BulkTable` stays for SQL Server central DB; collectors just need a driver to READ |
| Estate grid domains | Domain rules in `sql/21_estate.sql` — add CASE branches for each Platform |
| Alert thresholds | Some thresholds are engine-specific (PLE = MSSQL only); guard with Platform checks |

### config extension
```json
{
  "central": { "instance": "SQLMON01" },
  "cms": { "instance": "CMS01", "group": "PROD-SQL" },
  "redshift": [{ "clusterId": "analytics", "host": "...", "port": 5439, "database": "analytics" }],
  "oracle": [{ "serverId": "ORAPROD", "host": "ora-prod.internal", "port": 1521, "service": "ORCL" }],
  "aurora": [{ "serverId": "PG-PROD", "host": "pg-cluster.region.rds.amazonaws.com", "port": 5432, "database": "appdb" }],
  "db2": [{ "serverId": "DB2PROD", "host": "db2.internal", "port": 50000, "database": "SAMPLE" }],
  "couchbase": [{ "serverId": "CB-PROD", "host": "cb-node1.internal", "port": 8091 }]
}
```

Each engine section follows the same pattern: an array of targets with
engine-specific connection details. Credentials use DPAPI or env vars, same as today.

---

## Dashboard evolution

### Estate grid (the single pane of glass)
The estate grid already works with a `Platform` column. To add Oracle:

1. The Oracle collector writes into the same `mon.*` tables.
2. `rpt.EstateHealth` picks up Oracle servers automatically (they have rows in mon.*).
3. Domain rules in `sql/21_estate.sql` need CASE branches:
   - **Backup domain:** MSSQL checks `rpt.BackupHealth`, Oracle checks RMAN status.
   - **HA domain:** MSSQL checks AG sync, Oracle checks Data Guard lag.
   - **Disk domain:** same logic, different source volume types.

### Engine-specific tabs
Some tabs are universal (Estate, Disk, Alerts, App Owners, Servers), others are
engine-specific (AG Sync = MSSQL, VACUUM debt = Redshift). Strategy:

```javascript
// In app.js — show/hide tabs based on what platforms exist
const platforms = overview.Platforms || ['MSSQL'];  // from rpt.Overview
document.querySelectorAll('[data-engine]').forEach(btn => {
  btn.hidden = !platforms.includes(btn.dataset.engine);
});
```

- **Always visible:** Estate, Disk Forecast, Growth, Alerts, App Owners, Servers, Health
- **MSSQL only:** AG Sync (unless Oracle Data Guard is added → rename to "HA Replication")
- **Redshift only:** Table Maintenance (VACUUM/ANALYZE)
- **Engine-filtered:** Activity, Data Lag (show all engines, filter by platform)

---

## Implementation order (when the time comes)

| Phase | Engine | Effort | Why this order |
|-------|--------|--------|----------------|
| 1 (now) | MSSQL + Redshift | Done | The POC |
| 2a | Aurora PostgreSQL | Low | Already designed (portability ledger); collector is Npgsql reads |
| 2b | Oracle | Medium | Most common client ask; ODP.NET is well-documented |
| 3 | Db2 | Medium | Similar relational model; ODBC driver exists |
| 4 | Couchbase | Medium | REST API, different paradigm (no "tablespace"), but normalizes well |

**Each engine is additive.** You never need to touch the existing MSSQL/Redshift
collectors when adding Oracle. The central schema, dashboard, and alerting are
engine-agnostic by design.

---

## Base features every engine should have

Regardless of the database engine, each collector should provide these
**universal health metrics** that normalize into the existing schema:

| Metric | Why universal | mon.* table |
|--------|--------------|-------------|
| **Storage usage** | Every DB has disk/tablespace/bucket limits | `mon.DiskUsage` |
| **Replication lag** | AG, Data Guard, HADR, XDCR all reduce to "seconds behind" | `mon.DataLag` |
| **Backup recency** | Every DB should have backups with measurable RPO | `mon.BackupStatus` |
| **Active sessions** | Every DB has connections, some of which block | `mon.ActivitySnapshot` |
| **Instance vitals** | CPU, memory, key buffer metrics per engine | `mon.InstanceVitals` |
| **Failed logins** | Authentication failures are a universal security signal | `mon.FailedLogin` |
| **Object sizes** | Database/table/bucket growth over time | `mon.ObjectSize` |
| **Collection log** | Did the collector reach the target? | `cfg.CollectionLog` |

These eight metrics give you the estate grid, disk forecast, growth charts,
health view, and alerting — **for any engine** — using the existing dashboard
with zero UI changes. Engine-specific depth (Oracle ASM, Couchbase XDCR details,
Db2 diagnostic log) comes as additional tables and drill-in tabs.

---

## What this means for the POC

**Don't build any of this now.** The value of this document is that the POC
architecture already supports it — the three-layer separation, the `Platform`
column, the normalized `mon.*` tables, the `rpt.*` contract. When a client asks
"can this monitor our Oracle too?", the answer is "yes, by adding an Oracle
collector — the central database, dashboard, and alerting work unchanged." This
document proves that claim.
