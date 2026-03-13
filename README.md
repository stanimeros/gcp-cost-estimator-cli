# GCP Quota & Billing Report

Shell script that uses Google Cloud CLI and Cloud Billing API to create a report with **enabled billable services** across all billing-enabled GCP projects, showing quotas, SKUs, and how many quota units $10/day buys.

## Requirements

- **gcloud CLI** – installed and authenticated (`gcloud auth login`)
- **gcloud beta component** – for quota data; auto-installed by the script if missing (`gcloud components install beta`)
- **jq** – for JSON parsing (`brew install jq`)
- **curl** and **bc** – standard on macOS, used for billing API calls and arithmetic
- **IAM permissions** on each project:
  - `serviceusage.services.list` – to list enabled APIs
  - `serviceusage.quotas.get` – to read quota values (`gcloud beta quotas`)
  - `billing.resourceAssociations.list` – to check if billing is enabled (`cloud-billing.readonly` role)

## Usage

```bash
./gcloud-quota-billing-report.sh
```

The script automatically:
1. Lists all accessible GCP projects (`gcloud projects list`)
2. Skips projects without billing enabled
3. Processes each billing-enabled project and outputs one table per project

## Output

- **Terminal**: One table per project, sorted by Quota per $10/day (most expensive first)
- **File** (`billing-report.md`): One markdown section per project, plus a total summary footer (overwrites each run)

## Report Structure

```
# GCP Quota & Billing Report
**Projects:** <billing-enabled project IDs>

## <project-id>
**Services** N, **SKUs** N
| Service | Quota name | SKU(s) | Current quota | Quota per $10/day |
...

---
**Total services** N, **Total SKUs** N
```

## Columns

| Column | Description |
|--------|-------------|
| Service | GCP API service name (e.g. `bigquery.googleapis.com`) for console matching |
| Quota name | Quota display name, including interval when available (e.g. per day, per minute) |
| SKU(s) | Billing SKU descriptions for the service, truncated with ellipsis (…) after 80 chars |
| Current quota | Current quota value (or `unlimited` when applicable) |
| Quota per $10/day | How many quota units $10/day buys (from most expensive SKU), or **N/A** when not estimable |

## When Quota per $10/day is N/A

The value is shown as **N/A** when:

- **Unit mismatch** – Quota unit (e.g. Requests) does not match SKU unit (e.g. Storage GiB)
- **Rate-limit quotas** – e.g. "Requests per minute" (cost model differs from consumption)
- **No pricing data** – SKU has zero or missing price

## Unit Matching

For Quota per $10/day to be calculated, the Quota unit must match the SKU unit:

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

On subsequent runs within 24h, all `curl` and `gcloud beta quotas` calls are skipped. Only `gcloud projects list`, `gcloud beta billing projects describe`, and `gcloud services list` are called live each run.

## Execution Cost

**Free.** The Cloud Billing API is free for read operations (catalog, SKUs). gcloud quota commands use the Service Usage API, which does not charge for metadata reads.
