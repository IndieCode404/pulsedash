---
inclusion: always
---

# Product — Database Monitoring POC

A single console that monitors the client's database estate from **one central
server**, designed to run **wholly inside the client network**. SQL Server first;
architected so any other engine (starting with **AWS Aurora PostgreSQL**) is added
later without a rewrite.

## POC scope (what "done" means for this phase)
Build/harden, on ONE non-production estate:
1. Central repository database (portable schema — see `tech.md`).
2. Server inventory + application owners.
3. Core SQL Server collectors: **backup/RPO + CHECKDB, disk capacity forecast,
   agent-job failures** (the three DBAs ask about first).
4. A read-only dashboard that ranks the estate worst-first, with drill-through.
5. Deployment package + runbook.

## Explicitly OUT of scope for the POC
Redshift depth, the AI copilot, alerting integrations beyond email, and every
"full product" feature. Note them, don't build them.

## Success
A working console on the client's non-prod estate, reviewed against a baseline the
client agrees up front. There is a **go / no-go checkpoint before any production
instance is connected.**

## Baseline
A working prototype already exists (the `pulsedash` / DBADash codebase). **Reuse and
harden it — do not regenerate from scratch.** New work is: client deployment,
Aurora-portability hardening, and the security review.
