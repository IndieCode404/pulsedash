# Redshift cost anomaly — pointers &amp; how DBADash does it

Redshift bills you for **usage**, not rows, so a "cost anomaly" is an unusual
spike in a **cost driver**. There are two complementary layers: what AWS gives
you natively, and what DBADash computes from inside the cluster.

## 1. Native AWS (authoritative for $ — set these up)
These see the actual invoice, so treat them as the source of truth:

| Tool | What it catches | Pointer |
|------|-----------------|---------|
| **AWS Cost Anomaly Detection** | ML-based spend spikes on Redshift, alerts by email/SNS. Free. | Billing console → *Cost Anomaly Detection* → monitor for service **Amazon Redshift** |
| **Cost Explorer** | Break spend down by *usage type* (`…:Spectrum`, `…:Node`, `…:Storage`, `…:ServerlessCompute`) and by tag | Filter by service = Redshift, Group by *Usage Type* / *Tag* |
| **CloudWatch billing alarm** | Threshold alarm on `EstimatedCharges` | CloudWatch → Alarms → Billing |
| **Cost &amp; Usage Report (CUR)** | Line-item detail to Athena/QuickSight for deep analysis | Billing → *Cost &amp; Usage Reports* |
| **Cost Allocation Tags** | Attribute cost to team/app (pair with DBADash app owners) | Billing → *Cost Allocation Tags* |

## 2. In-cluster drivers (what DBADash collects &amp; scores)
AWS billing lags ~1 day; the in-cluster system tables are near-real-time, so
DBADash watches the **leading indicators** and flags spikes the same collection
cycle. Collected by `deploy\Collect-Redshift.ps1` from
`redshift\redshift_metrics.sql` (the `--==COST==--` block):

| Metric | System source | Why it drives cost |
|--------|---------------|--------------------|
| `spectrum_tb_1d` | `SVL_S3QUERY_SUMMARY.s3_scanned_bytes` | Redshift Spectrum is billed **~$5 per TB scanned** — the classic runaway bill |
| `bytes_scanned_tb_1d` | `SYS_QUERY_HISTORY.scan_size_bytes` | Proxy for workload weight → concurrency-scaling / RA3 elastic cost |
| `serverless_rpu_hours_1d` | `SYS_SERVERLESS_USAGE` | Serverless is billed per **RPU-hour** (commented out by default; enable on Serverless) |
| `storage_gb` | `STV_PARTITIONS` | Managed storage growth = ongoing $/GB-month |

Other worth adding for your shop: concurrency-scaling seconds beyond the free
tier, unsorted/unvacuumed table bloat, and datashare egress.

### How the scoring works
`cfg.usp_Detect_CostAnomaly` (in `sql\09_cost.sql`) keeps a rolling **14-day
baseline** per metric and flags today's value with a **z-score**:

```
z = (today − mean_baseline) / stddev_baseline
```

- **WARN**: z ≥ 2.5, *or* ≥ 50% above baseline (covers low-variance metrics)
- **CRIT**: z ≥ 4.0, *or* ≥ 100% above baseline
- Only **positive** spikes are flagged (a quiet day never costs you money).

Results land in `mon.CostAnomaly` → shown on the dashboard **Cost Anomaly** tab
and rolled into the **Alerts** pipeline (so a cost spike can email you).

Tune the thresholds on the proc:
```sql
EXEC cfg.usp_Detect_CostAnomaly @Window=21, @WarnZ=3.0, @CritPct=150;
```

## Recommended split
- Let **AWS Cost Anomaly Detection** own "did the invoice move" (dollar truth).
- Let **DBADash** own "which query/table/cluster is about to move it, right now"
  (operational, same-day, and correlated with the app owner to call).
