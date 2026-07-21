# docs

| File | What it is |
|------|-----------|
| [COST_ANOMALY.md](COST_ANOMALY.md) | Redshift cost-anomaly playbook — AWS-native (Cost Anomaly Detection, Cost Explorer, CUR) vs. the in-cluster z-score detection DBADash performs, and when to use which. |
| [DBADash-Monitoring-Proposal.pptx](DBADash-Monitoring-Proposal.pptx) | **Client pitch deck** (11 slides) — the problem, coverage, architecture, technical requirements, data-protection guarantees, the optional AI layer, business value, roadmap, and a 4-week pilot ask. Speaker notes on every slide. |

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
