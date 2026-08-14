# Portability ledger — SQL Server → AWS Aurora PostgreSQL

**Commitment:** the POC runs on SQL Server now, but the **store layer** (repository
schema, ingestion, reporting views) is built so moving it to Aurora PostgreSQL later
is a **port, not a rewrite**. This file is the running proof. Update it on every
change that touches schema, views, ingestion, or procs.

> Scope note: the **collectors** read SQL Server DMVs and are inherently
> SQL-Server-specific — they are *not* in scope for portability. You monitor SQL
> Server with T-SQL; you'd write separate PostgreSQL collectors to monitor Postgres.
> Portability is about where the data is **stored and reported**, which is the part a
> client would move to Aurora.

## The whole migration is three functions + the views
Everything engine-coupled in the store layer is isolated behind three seams. Port
these and the reporting SQL, and you're done:

| Seam | Today (SQL Server) | Aurora PostgreSQL |
|------|--------------------|-------------------|
| Connection | `Common.ps1 → Get-SqlConnString` (`SqlConnectionStringBuilder`) | Npgsql connection string builder |
| Bulk ingest | `Common.ps1 → Write-BulkTable` (`SqlBulkCopy`) | Npgsql binary `COPY` |
| Secret store | `Common.ps1 → Protect/Unprotect-DbaDashSecret` (DPAPI) | AWS Secrets Manager / KMS, or `pgcrypto` |

**Rule:** no other file in the store layer may open a connection, bulk-load, or
handle a secret directly. If one does, fix it and note it below.

## Type map
| SQL Server | Aurora PostgreSQL | Note |
|-----------|-------------------|------|
| `NVARCHAR(n)` / `SYSNAME` | `varchar(n)` / `text` | `SYSNAME` = `nvarchar(128)`; use `text`. |
| `DATETIME2(0)` | `timestamp` (store UTC) | |
| `BIGINT IDENTITY(1,1)` | `bigint GENERATED ALWAYS AS IDENTITY` | or `bigserial` |
| `BIT` | `boolean` | ODBC-sourced 0/1 already uses `TINYINT` in one place — maps to `smallint`. |
| `VARBINARY(MAX)` | `bytea` | the DPAPI blob column |
| `DECIMAL(p,s)` / `FLOAT` | `numeric(p,s)` / `double precision` | |
| `AS (...) PERSISTED` computed col | generated column **or** compute in the view | ⚠ rework item — see ledger. |

## Function / syntax map (reporting views — the hotspot)
| SQL Server | Aurora PostgreSQL | Prefer now? |
|-----------|-------------------|-------------|
| `ISNULL(a,b)` | `COALESCE(a,b)` | ✅ write `COALESCE` today — portable in both |
| `TOP (n)` | `LIMIT n` / `FETCH FIRST n ROWS ONLY` | ✅ use `FETCH … ONLY` where practical |
| `STUFF((… FOR XML PATH('')),…)` | `string_agg(x, ',')` | ⚠ rework at port time |
| `IIF(c,a,b)` | `CASE WHEN c THEN a ELSE b END` | ✅ write `CASE` today |
| `GETDATE()` / `SYSUTCDATETIME()` | `now()` / `now() at time zone 'utc'` | isolate; small |
| `DATEDIFF(unit,a,b)` | `EXTRACT`/interval arithmetic | ⚠ semantics differ — verify |
| `DATEADD(unit,n,d)` | `d + n * interval '1 unit'` | ⚠ |
| `DATEDIFF_BIG(SECOND,…)` | `EXTRACT(EPOCH FROM (b-a))` | forecast proc uses this |
| `CROSS APPLY` | `LATERAL` join | |
| `CONCAT`, window functions, CTEs, `MERGE` | supported (MERGE = PG 15+) | ✅ mostly portable |
| `sp_executesql` guarded dynamic SQL | `DO`/`EXECUTE` in PL/pgSQL | collectors only, not the store |

## Current known SQL-Server-specific dependencies (seed — verify & extend)
Populate this by reading the code during spec tasks 2–4. Known so far:

| Where | Construct | Port action |
|-------|-----------|-------------|
| `sql/02` `mon.DiskUsage` | `FreeBytes` / `UsedPct` **PERSISTED** computed columns | move the calc into `rpt.*` views, or use a PG generated column |
| store-wide | `SYSNAME` columns | → `text` (or `varchar(128)`) |
| `rpt.*` views | any `ISNULL` / `TOP` / `STUFF…FOR XML` / `IIF` | rewrite to the portable form (map above) |
| `usp_Refresh_DiskForecast` | `DATEDIFF_BIG` least-squares math in T-SQL | translate to PL/pgSQL, or compute in the app layer |
| `usp_Evaluate_Alerts`, `usp_Purge_History`, findings | T-SQL procs | keep thin; translate to PL/pgSQL at port time |
| `Common.ps1` | `SqlBulkCopy`, `SqlConnectionStringBuilder`, DPAPI | the three isolated seams above |
| `Start-Dashboard.ps1` | `SqlClient` reads of `rpt.*` | swap provider to Npgsql; queries are ANSI-leaning |

## Migration runbook (when/if the client moves the store to Aurora)
1. Recreate the schema on Aurora using the type map (script generated from `sql/`).
2. Translate `rpt.*` views (function map) and the handful of procs to PL/pgSQL.
3. Reimplement the three seams for Npgsql + `COPY` + a Postgres secret store.
4. Point the collectors' write path and the dashboard's read path at Aurora.
5. Collectors' target-side T-SQL is unchanged (still monitoring SQL Server).

Keeping this file current is task 11 of the foundation spec, and the artifact you
show the client to prove the commitment is real.
