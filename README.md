# GCP Quota & Billing Report

Shell script that uses Google Cloud CLI and Cloud Billing API to create a report with **enabled billable services** across all accessible GCP projects, showing quotas, SKUs, estimated daily cost, and how many quota units $10/day buys.

## Requirements

- **gcloud CLI** – authenticated with `cloud-billing.readonly` scope
- **jq** – `brew install jq`
- **Cloud Billing API** enabled in the project
- **gcloud beta** – for quota data (`gcloud components install beta`)

## Usage

```bash
./gcloud-quota-billing-report.sh
```

The script automatically processes **all accessible GCP projects** (from `gcloud projects list`).

## Output

- **Terminal**: Table sorted by Est. Price Daily (higher first)
- **File** (`billing-report.md`): Full markdown report with summary stats (overwrites each run)

## Report Summary

The report header shows:
- **Projects** – list of processed project IDs
- **Services** – total number of enabled billable services across all projects
- **SKUs** – total SKU count across all services

## Columns

| Column | Description |
|--------|-------------|
| Project | GCP project ID |
| Service | GCP API service name (e.g. `bigquery.googleapis.com`) for console matching |
| Quota name | Quota display name, including interval when available (e.g. per day, per minute) |
| SKU(s) | Billing SKU descriptions for the service, truncated with ellipsis (…) after 80 chars |
| Current quota | Current quota value (or `unlimited` when applicable) |
| Quota per $10/day | How many quota units $10/day buys (from most expensive SKU), or **N/A** when not estimable |
| Est. price daily | Estimated daily cost at full quota usage, or **N/A** when not estimable |

## When Quota per $10/day and Est. Price Daily are N/A

The values are shown as **N/A** when:

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
