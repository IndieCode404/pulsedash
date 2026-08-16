# docs

| File | What it is |
|------|-----------|
| [KIRO-KICKOFF.md](KIRO-KICKOFF.md) | **Start here for the POC build in Kiro** — setup, API-cost discipline, the kickoff prompt to paste, and the task workflow. Works with the steering + spec in `.kiro/`. |
| [PORTABILITY.md](PORTABILITY.md) | **SQL Server → AWS Aurora PostgreSQL** ledger — the type/function maps and the three isolated engine seams that make the store layer portable. The artifact that backs the "migrate to Aurora without a challenge" commitment. |
| [SECURITY-CHECKLIST.md](SECURITY-CHECKLIST.md) | Reviewable gate so **the HTML dashboard can't create vulnerabilities** — XSS/output-encoding, CSP, CSRF, SQL injection, path traversal, secrets, least privilege. |
| [COST_ANOMALY.md](COST_ANOMALY.md) | Redshift cost-anomaly playbook — AWS-native (Cost Anomaly Detection, Cost Explorer, CUR) vs. the in-cluster z-score detection DBADash performs, and when to use which. |
| [DBADash-Monitoring-Proposal.pptx](DBADash-Monitoring-Proposal.pptx) | **Client pitch deck** (11 slides) — problem, coverage, architecture, requirements, data-protection, optional AI layer, business value, roadmap, pilot ask. |
| [Database-Monitoring-POC-Proposal.pptx](Database-Monitoring-POC-Proposal.pptx) | **POC approval deck** (12 slides, pre-build framing) — architecture diagram, tech stack, scope, security, Claude access, indicative business case, 8-week plan. |

## Kiro build guardrails

The POC is built in **Kiro** under always-on steering in `.kiro/steering/`
(`product.md`, `tech.md`, `guardrails.md`) with the first spec in
`.kiro/specs/foundation/`. Those files encode the non-negotiables — data residency
(nothing leaves the network, no client data in prompts), read-only on targets,
Aurora portability, HTML security, and API-cost discipline. Read
[KIRO-KICKOFF.md](KIRO-KICKOFF.md) first.

## About the deck

It's a **sales/stakeholder artifact**, not product documentation — kept here so it
travels with the code and stays in sync as capabilities change.

Two claims in it are deliberately worded and should not be "simplified" when reused:

- **"Your data never leaves your network"** applies to the **monitoring platform**,
  which makes no outbound call of any kind. That is verifiable in this repo.
- **The AI layer is optional and separate.** Claude cannot be self-hosted on-prem.
  If enabled, the deck proposes **Amazon Bedrock inside the client's own AWS
  account**, so requests stay in their cloud boundary, and states that only
  aggregated metrics are sent — never table data or rows. Do not restate this as
  "the AI runs locally"; a security reviewer will and should challenge it.

No performance figures are quoted anywhere, because none have been measured yet —
slide 9 commits to baselining during the pilot instead. Keep it that way until
there are real numbers from a client environment.

**If you edit it:** update the capability counts on slides 3 and 4 (currently
14 views / 30 collectors — 18 MSSQL + 12 Redshift) whenever collectors are added
or removed.
