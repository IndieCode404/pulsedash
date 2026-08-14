# Getting started in Kiro (client machine)

This project ships with Kiro **steering** (`.kiro/steering/`) and a first **spec**
(`.kiro/specs/foundation/`). Steering files are injected into every request, so the
model always has the guardrails — you don't have to repeat them.

## 1. Set up
1. Open this project folder in Kiro on the client machine.
2. Confirm Kiro sees the steering files (`.kiro/steering/product.md`, `tech.md`,
   `guardrails.md`) and the spec under `.kiro/specs/foundation/`.
3. Put **no client specifics** in these files — use placeholders. Real instance
   names / credentials live only in `deploy/config/dbadash.json`, which is
   git-ignored and must never be pasted into the assistant.

## 2. Keep API spend low (it's metered and monitored)
- **Reuse the existing code. Never ask it to "rebuild" or "regenerate" a file that
  exists** — ask for a specific edit.
- Work **one spec task at a time** (open `tasks.md`, do task N, review, commit).
- Use the **cheapest model that fits**; escalate only for hard reasoning, then drop
  back.
- **Turn off agent hooks that run on save** (or any auto-run automation) during the
  POC — they re-invoke the model on every change and quietly rack up spend.
- Keep context tight: rely on steering + the open file, not repo-wide scans.
- If a task balloons (many files, repeated retries), **stop and checkpoint** — that's
  usually a sign the ask was too big, not that it needs more tokens.

## 3. Kickoff prompt (paste as your first message)

> You are working inside this repository under the Kiro steering files in
> `.kiro/steering/` — treat `guardrails.md` as hard constraints. We are running the
> **foundation slice** in `.kiro/specs/foundation/`.
>
> Context: a working prototype already exists in this repo (the pulsedash/DBADash
> code). **Reuse and harden it — do not regenerate files that exist; make small,
> targeted edits.** The central store must stay portable to AWS Aurora PostgreSQL
> (see `tech.md` + `docs/PORTABILITY.md`), and the HTML dashboard must not introduce
> vulnerabilities (see `docs/SECURITY-CHECKLIST.md`).
>
> Hard rules to confirm you understand before writing code: (1) nothing leaves the
> client network and no client data goes into prompts; (2) monitored targets are
> read-only — SELECT only; (3) stay on the approved non-prod instances; (4) work one
> task at a time and keep diffs small to control API spend.
>
> Start with **task 1** in `tasks.md`: confirm the central database deploys to the
> non-prod instance and creates only `[DBADash]`. Tell me the exact commands to run,
> wait for my output, then proceed. Do not run ahead to later tasks.

## 4. Workflow
`spec → pick the next unchecked task → smallest edit → you run it → paste result →
model verifies → commit`. Update `tasks.md` checkboxes and `docs/PORTABILITY.md` as
you go. Deploy/collect commands and their checks are in the main `README.md`.

## 5. When you hit an error
Paste the **error text** (with any client-identifying values redacted) or the
`cfg.CollectionLog` message. Fixes so far have been 1–2 lines — ask for the specific
change, not a rewrite.
