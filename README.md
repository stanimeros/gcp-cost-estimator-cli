# GCP Quota & Billing Report

Shell script that uses Google Cloud CLI and Cloud Billing API to create a report with **enabled billable services**, quotas, SKUs, estimated daily cost, and suggested quota limits within a monthly budget.

## Requirements

- **gcloud CLI** – authenticated with `cloud-billing.readonly` scope
- **jq** – `brew install jq`
- **Cloud Billing API** enabled in the project
- **gcloud beta** – for quota data (`gcloud components install beta`)

## Usage

```bash
./gcloud-quota-billing-report.sh [TARGET_BUDGET_USD] [PROJECT_ID]
```

Examples:

```bash
./gcloud-quota-billing-report.sh 500
# Prompts for project ID if not provided

./gcloud-quota-billing-report.sh 1000 my-project-id
```

## Output

- **Terminal**: Table sorted by Est. Price Daily (higher first)
- **File** (`billing-report.md`): Full markdown report with summary stats (overwrites each run)

## Report Summary

The report header shows:
- **Services** – number of enabled billable services
- **SKUs** – total SKU count across services
- **Daily budget** – monthly budget ÷ 30
- **Per service daily budget** – daily budget ÷ number of services

## Columns

| Column | Description |
|--------|-------------|
| Service | GCP API service name (e.g. `bigquery.googleapis.com`, `places-backend.googleapis.com`) for console matching |
| Quota name | Quota display name, including interval when available (e.g. per day, per minute) |
| SKU(s) | Billing SKU descriptions for the service, truncated with ellipsis (…) after 80 chars |
| Current quota | Current quota value (or `unlimited` when applicable) |
| Suggested quota | Max units/day to stay within this service's budget share |
| Est. price daily | Estimated daily cost at full quota usage, or **N/A** when not estimable |

## When Est. Price Daily is N/A

The estimate is shown as **N/A** when:

- **Unlimited quota** – no numeric limit to base calculation on
- **Unit mismatch** – Quota unit (e.g. Requests) does not match SKU unit (e.g. Storage GiB)
- **Rate-limit quotas** – e.g. "Requests per minute" (cost model differs from consumption)
- **Sanity cap** – calculated value > 100,000 (likely quota/SKU mismatch)

## Unit Matching

For a cost estimate, the Quota unit must match the SKU unit:

| Quota unit | SKU unit | Result |
|------------|----------|--------|
| Bytes (By, GiBy, MiBy) | GiBy.mo, GiBy, By | ✅ Calculate |
| Requests (metricUnit "1", name has "request") | request, 1000, 1k | ✅ Calculate |
| Requests | Storage GiB | ❌ N/A |
| Storage bytes | Requests | ❌ N/A |

## Cache

Billing catalog (services + SKUs) and quota data are cached for 24h in `.cache/` (in the script folder):

- `CACHE_TTL=0` – disable cache
- `CACHE_DIR=/custom/path` – use a different folder

## Execution Cost

**Free.** The Cloud Billing API is free for read operations (catalog, SKUs). gcloud quota commands use the Service Usage API, which does not charge for metadata reads.
