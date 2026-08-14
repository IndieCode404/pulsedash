# Foundation slice — tasks

Do these **one at a time**, smallest diff that satisfies the task, then checkpoint.
Most already exist in the prototype — the job is verify → port-harden → prove, not
rebuild. Tick a box only after it's actually checked.

- [ ] 1. **Confirm the baseline builds.** Deploy the central DB to the non-prod
  instance (`Deploy-DBADash.ps1`). Verify it creates `[DBADash]` and nothing else.
  _Req 1_
- [ ] 2. **Portability pass on the schema.** Read `sql/01`–`02`; list every
  SQL-Server-specific type/feature in `docs/PORTABILITY.md` with its Postgres
  equivalent. Flag `PERSISTED` computed columns and `SYSNAME`. Do not change
  behaviour — just document (and note anything that should be reworked). _Req 1, 5_
- [ ] 3. **Portability pass on `rpt.*` views.** Read the core views; where they use
  `ISNULL`/`TOP`/`STUFF…FOR XML`/`IIF`, note the ANSI/Postgres form in
  `docs/PORTABILITY.md`. Prefer rewriting to the portable form when the diff is
  small and safe. _Req 1, 5_
- [ ] 4. **Confirm the three engine seams are isolated.** Verify `Get-SqlConnString`,
  `Write-BulkTable`, and the DPAPI helpers are the ONLY SQL-Server-coupled code in
  the store layer. If any collector or view bypasses them, note it. _Req 1_
- [ ] 5. **Dry-run the targets.** `Show-Targets.ps1` against the client config;
  confirm it lists only approved non-prod instances and connects to none. _Req 2, 3_
- [ ] 6. **First real collection.** `Collect-All.ps1`; confirm `cfg.CollectionLog`
  shows OK per instance. Fix any ERROR by reading its message. All queries stay
  `SELECT`. _Req 3_
- [ ] 7. **Verify the three collectors' data.** Spot-check `rpt.BackupHealth`,
  `rpt.DiskForecast`, `rpt.JobFailures` return sensible rows for the estate. _Req 3_
- [ ] 8. **Dashboard smoke test.** Start it on a free port (localhost); confirm the
  KPI strip and the three domains render from `rpt.*`, and that the estate is ranked
  worst-first. _Req 4_
- [ ] 9. **HTML security gate.** Walk `docs/SECURITY-CHECKLIST.md`: confirm `esc()`
  on every rendered value, no unescaped `innerHTML`, CSRF header present, path
  containment on, localhost-only. Fix anything that fails. _Req 4, 5_
- [ ] 10. **Package + runbook.** `Package-DBADash.ps1` (no `-WithDemoData`); confirm
  the zip has no secrets/demo seeds; write/refresh the install runbook. _Req 6_
- [ ] 11. **Portability ledger review.** `docs/PORTABILITY.md` is complete and current
  — this is the artifact that proves the Aurora migration is a port, not a rewrite.
  _Req 5_

**Definition of done:** tasks 1–11 checked, one clean collection logged, dashboard
renders real non-prod data, security checklist passed, portability ledger current.
