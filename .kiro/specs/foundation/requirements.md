# Foundation slice — requirements

The first, provable slice of the POC: a portable central repository, server
inventory, three core SQL Server collectors, and a worst-first dashboard —
deployed to one non-production estate. Adapt from the existing prototype where it
exists; only build net-new where it does not.

## Requirement 1 — Central repository
**As** the platform, **I want** one central SQL Server database with a clean,
portable schema, **so that** all monitoring data lives in one place and can move to
Aurora PostgreSQL later.
- WHEN the deploy runs against a fresh instance THE SYSTEM SHALL create the database
  and its schemas, and touch nothing outside that database.
- IF a database of the same name already exists THE SYSTEM SHALL stop and report,
  not alter it.
- THE SYSTEM SHALL keep the schema, reporting views, and ingestion within the
  portability rules in `tech.md`, and record any SQL-Server-specific construct in
  `docs/PORTABILITY.md`.

## Requirement 2 — Inventory & owners
**As** a DBA, **I want** a managed list of monitored servers and their application
owners, **so that** collection targets and alert routing are explicit.
- THE SYSTEM SHALL resolve MSSQL targets from the config list and/or a CMS group and
  the inventory table, and merge them deterministically.
- THE SYSTEM SHALL provide a dry-run that lists which servers WOULD be contacted,
  connecting to none of them.
- THE SYSTEM SHALL store an application owner (name, team, email, criticality) per
  server/app.

## Requirement 3 — Core collectors (read-only)
**As** a DBA, **I want** backup/recovery, disk capacity, and agent-job health
collected on a schedule, **so that** the first-morning questions are answered.
- WHILE collecting THE SYSTEM SHALL issue only `SELECT` statements against targets.
- THE SYSTEM SHALL capture, per instance: last full/diff/log backup + last good
  CHECKDB per DB; volume used/total with a days-to-full forecast; agent-job failures
  in the last 24h.
- IF one target or one query fails THE SYSTEM SHALL log it to `cfg.CollectionLog`
  with the reason and continue with the others.

## Requirement 4 — Worst-first dashboard
**As** a DBA, **I want** a read-only dashboard ranked by severity with drill-through,
**so that** the first screen shows what needs attention now.
- THE SYSTEM SHALL read only `rpt.*` views, never raw `mon.*` tables.
- THE SYSTEM SHALL escape every value rendered into HTML (no unescaped `innerHTML`).
- THE SYSTEM SHALL bind to localhost only and require the CSRF header on state-changing
  requests.

## Requirement 5 — Security & portability gates (acceptance)
**As** the client's reviewer, **I want** the slice to pass a security and portability
review, **so that** it is safe to connect to real instances.
- THE SYSTEM SHALL pass every item in `docs/SECURITY-CHECKLIST.md`.
- THE SYSTEM SHALL have a current `docs/PORTABILITY.md` listing every store-layer
  dependency on SQL Server and its Aurora PostgreSQL equivalent.

## Requirement 6 — Deployability
**As** the operator, **I want** a single package and a runbook, **so that** the POC
can be installed on the client box without the source repo.
- THE SYSTEM SHALL build a runtime-only package (no build noise, no secrets, no demo
  seeds by default) and a step-by-step runbook.
