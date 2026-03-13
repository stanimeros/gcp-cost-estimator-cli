# GCP Quota & Billing Report

Shell script that uses Google Cloud CLI and Cloud Billing API to create a table with project, service SKU, current quota, estimated price daily, and suggested quota to meet the budget.

## Requirements

- **gcloud CLI** – authenticated with `cloud-billing.readonly` scope
- **jq** – `brew install jq`
- **Cloud Billing API** enabled in the project
- (Optional) `gcloud components install beta` for quota data

## Usage

```bash
./gcloud-quota-billing-report.sh 500
# Prompts for project ID if not provided

./gcloud-quota-billing-report.sh 1000 my-project-id
```

## Output

- **Terminal**: Table with Project, Service, SKU, Quota, Est. Price Daily, Suggested Quota (sorted by cost)
- **File** (`billing-report.md`): Full report (overwrites each time)

## Columns

| Column | Description |
|--------|-------------|
| Project | GCP project ID |
| Service | Service name (e.g. BigQuery, Cloud Run) |
| SKU | Billing SKU description |
| Current Quota | Current quota (or "unlimited" when applicable) |
| Est. Price Daily | Estimated daily cost at full quota usage |
| Suggested Quota | Suggested quota to stay within budget |

## Cache

The billing catalog (services + SKUs) is cached for 24h in `.cache/` (in the script folder):
- `CACHE_TTL=0` to disable
- `CACHE_DIR=/custom/path` for a different folder

## Request-based APIs (Maps, Vision, etc.)

APIs that charge per 1000 requests (Maps, Vision, Speech, Translation) are included. Suggested quota shows max requests/day within budget.

## Execution Cost

**Free.** The Cloud Billing API is free for read operations (catalog, SKUs). gcloud commands use the Service Usage API which also does not charge for metadata reads.
