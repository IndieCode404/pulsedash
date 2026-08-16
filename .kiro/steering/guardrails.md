---
inclusion: always
---

# Non-negotiable guardrails

These override convenience. If a request conflicts with one, stop and flag it.

## 1. Data residency — nothing leaves the client network
- The monitoring platform makes **no outbound network call** of any kind. No
  telemetry, no phone-home, no third-party API from the running product.
- **Never put client data in a model prompt.** Not table rows, not real server
  names, not credentials, not connection strings, not error text that contains
  business data. Use placeholders (`<INSTANCE>`, `<DB>`, synthetic values) when
  asking the model for help. The model is a **coding tool**, not a runtime component.
- Do not paste production query results, `mon.*` contents, or `cfg.Servers` rows into
  the assistant.

## 2. Read-only on monitored targets
- Every target-side query is a `SELECT`. **No `INSERT`/`UPDATE`/`DELETE`/`DROP`/
  `ALTER`/DDL against a monitored server, ever.** Writes happen only inside the
  central repository database.
- No agents, no jobs, no schema installed on monitored servers.

## 3. Stay inside approved scope
- Connect only to the **non-production** instances approved for the POC. No
  production instance until the week-6 go/no-go.
- Confirm the target list with `Show-Targets.ps1` (dry run) before any collection.

## 4. Secrets
- No plaintext secrets in code, config committed to git, prompts, or logs.
- Stored target passwords are DPAPI-encrypted; the store exposes only `HasPassword`.
- Prefer Windows/integrated auth and environment variables over stored passwords.

## 5. The HTML dashboard must not create vulnerabilities
Full checklist in `docs/SECURITY-CHECKLIST.md`. The always-on rules:
- **Encode all output.** Every value rendered into HTML goes through the `esc()`
  helper. Never assign untrusted data to `innerHTML` unescaped; never build a DOM
  string from raw collected data (login names, query text, server/DB names).
- **No inline event handlers built from data**, no `eval`, no `new Function`.
- **Parameterised SQL only** in the API — no string interpolation of values.
- Keep **CSRF** (custom header + same-origin check), **path containment** on the
  static file server, and **localhost binding**. Do not weaken them.
- The dashboard has no built-in auth — it stays localhost-only until a reverse proxy
  with authentication is added. Do not bind it to `0.0.0.0` or a public interface.

## 6. Portability (Aurora PostgreSQL)
Keep the **store layer** portable per `tech.md`; update `docs/PORTABILITY.md` on every
change that touches schema, views, ingestion, or procs. Collectors stay SQL-Server.

## 7. Cost / token discipline (client API usage is metered and monitored)
- **Reuse the existing prototype. Do not regenerate files that already exist — edit
  them.** Whole-file rewrites and "start over" burn tokens for no gain.
- Work **one spec task at a time**; do not run long autonomous loops or
  agent-on-save hooks that re-run on every keystroke.
- Read only the file section you need; rely on these steering files for context
  rather than re-scanning the repo each turn.
- Use the **most economical model that fits the task**; escalate to a larger model
  only for genuinely hard reasoning, then drop back.
- If a task starts ballooning (many files, repeated retries), **stop and checkpoint
  with the human** rather than pushing on.

## 8. Verify, don't assume
- Parse-check every PowerShell change; validate SQL intent by reading, and run one
  collection through `cfg.CollectionLog` before claiming it works.
- State honestly what was and wasn't executed. No "should work" without a check.
