# GCP Quota & Billing Report

Shell script που χρησιμοποιεί το Google Cloud CLI και το Cloud Billing API για να δημιουργεί πίνακα με project, service SKU, current quota, estimated price daily και suggested quota για να πληρούν το budget.

## Απαιτήσεις

- **gcloud CLI** – authenticated με `cloud-billing.readonly` scope
- **jq** – `brew install jq`
- **Cloud Billing API** enabled στο project
- (Προαιρετικά) `gcloud components install beta` για quota data

## Χρήση

```bash
./gcloud-quota-billing-report.sh 500
./gcloud-quota-billing-report.sh 1000 my-project-id

# Γρήγορο τρέξιμο χωρίς quota (SKIP_QUOTA=1)
SKIP_QUOTA=1 ./gcloud-quota-billing-report.sh 500
```

## Έξοδος

- **Terminal**: Πίνακας με Project, Service, SKU, Quota, Est. Price Daily, Suggested Quota (sorted by cost)
- **File** (`billing-report.md`): Πλήρες report (overwrites κάθε φορά)

## Στήλες

| Στήλη | Περιγραφή |
|-------|-----------|
| Project | GCP project ID |
| Service | Όνομα service (π.χ. BigQuery, Cloud Run) |
| SKU | Billing SKU description |
| Current Quota | Τρέχον quota (N/A αν SKIP_QUOTA=1) |
| Est. Price Daily | Εκτιμώμενο ημερήσιο κόστος ανά πλήρη χρήση quota |
| Suggested Quota | Προτεινόμενο quota για να μείνεις εντός budget |

## Cache

Το billing catalog (services + SKUs) cache-άρεται για 24h στο `~/.cache/gcloud-quota-pricing/`:
- `CACHE_TTL=0` για απενεργοποίηση
- `CACHE_DIR=/custom/path` για άλλο φάκελο

## Request-based APIs (Maps, Vision, κλπ)

Περιλαμβάνονται APIs που χρεώνουν ανά 1000 requests (Maps, Vision, Speech, Translation). Το suggested quota δείχνει max requests/day εντός budget.

## Κόστος εκτέλεσης

**Δωρεάν.** Το Cloud Billing API είναι δωρεάν για read operations (catalog, SKUs). Τα gcloud commands χρησιμοποιούν Service Usage API που επίσης δεν χρεώνει για metadata reads.
