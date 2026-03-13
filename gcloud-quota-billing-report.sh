#!/usr/bin/env bash
#
# GCP Quota & Billing Report
# Table with project, service SKU, current quota, estimated price daily,
# suggested quota to meet the budget.
#
# Usage:
#   ./gcloud-quota-billing-report.sh [TARGET_BUDGET_USD] [PROJECT_ID]
#   If PROJECT_ID is omitted, prompts interactively for project selection.
#

set -euo pipefail

# --- Configuration ---
TARGET_BUDGET_USD=$(echo "${1:-}" | tr -d '[:space:]')
PROJECT_ID=$(echo "${2:-}" | tr -d '[:space:]')
REPORT_FILE="billing-report.md"
BUDGET_DAILY=0
QUOTA_TIMEOUT=2
# Cache: in script folder (.cache/), TTL 24h. Set CACHE_TTL=0 to disable.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/.cache}"
CACHE_TTL="${CACHE_TTL:-86400}"

# Map: API service name -> Billing API display name
# Used to match enabled services to billing catalog
get_billing_display_name() {
    case "$1" in
        compute.googleapis.com) echo "Compute Engine" ;;
        bigquery.googleapis.com) echo "BigQuery" ;;
        storage.googleapis.com|storage-component.googleapis.com) echo "Cloud Storage" ;;
        run.googleapis.com) echo "Cloud Run" ;;
        cloudfunctions.googleapis.com) echo "Cloud Functions" ;;
        dataflow.googleapis.com) echo "Dataflow" ;;
        dataproc.googleapis.com) echo "Dataproc" ;;
        spanner.googleapis.com) echo "Cloud Spanner" ;;
        sqladmin.googleapis.com) echo "Cloud SQL" ;;
        redis.googleapis.com) echo "Memorystore for Redis" ;;
        logging.googleapis.com) echo "Cloud Logging" ;;
        monitoring.googleapis.com) echo "Cloud Monitoring" ;;
        pubsub.googleapis.com) echo "Cloud Pub/Sub" ;;
        aiplatform.googleapis.com) echo "Vertex AI" ;;
        generativelanguage.googleapis.com) echo "Generative Language API" ;;
        vision.googleapis.com) echo "Cloud Vision API" ;;
        maps-backend.googleapis.com|maps.googleapis.com) echo "Maps" ;;
        speech.googleapis.com) echo "Cloud Speech-to-Text" ;;
        translate.googleapis.com) echo "Cloud Translation" ;;
        *) echo "" ;;
    esac
}

# --- Colors ---
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# --- Prerequisites ---
check_prerequisites() {
    if ! command -v gcloud &>/dev/null; then
        log_error "gcloud CLI not found."
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        log_error "jq not found. Install: brew install jq"
        exit 1
    fi
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
        log_error "Not authenticated. Run: gcloud auth login"
        exit 1
    fi
    if [[ -z "$PROJECT_ID" ]]; then
        local default_project
        default_project=$(gcloud config get-value project 2>/dev/null || true)
        if [[ -t 0 ]]; then
            echo ""
            log_info "Available projects:"
            gcloud projects list --format="table(projectId,name)" 2>/dev/null | head -20
            echo ""
            if [[ -n "$default_project" ]]; then
                read -p "Enter project ID [${default_project}]: " PROJECT_ID
            else
                read -p "Enter project ID: " PROJECT_ID
            fi
            PROJECT_ID=$(echo "${PROJECT_ID:-$default_project}" | tr -d '[:space:]')
        else
            PROJECT_ID="$default_project"
        fi
        [[ -z "$PROJECT_ID" ]] && { log_error "Project not found."; exit 1; }
        log_info "Project: $PROJECT_ID"
    fi
    if [[ -z "$TARGET_BUDGET_USD" ]]; then
        TARGET_BUDGET_USD=100
        log_warn "Default budget: $TARGET_BUDGET_USD USD"
    fi
    BUDGET_DAILY=$(echo "scale=4; $TARGET_BUDGET_USD / 30" | bc 2>/dev/null || echo "3.33")
}

# --- Cache helpers ---
# Returns cached content if fresh, else empty. Usage: cached="$(cache_get "key")"
cache_get() {
    local key="$1"
    local file="${CACHE_DIR}/${key}.json"
    [[ "$CACHE_TTL" -le 0 ]] && return 1
    [[ -f "$file" ]] || return 1
    local age
    local mtime
    mtime=$(stat -f %m "$file" 2>/dev/null) || mtime=$(stat -c %Y "$file" 2>/dev/null)
    age=$(($(date +%s) - ${mtime:-0}))
    [[ "$age" -lt "$CACHE_TTL" ]] || return 1
    cat "$file" 2>/dev/null
}

cache_set() {
    local key="$1"
    local content="$2"
    [[ "$CACHE_TTL" -le 0 ]] && return
    mkdir -p "$CACHE_DIR"
    echo "$content" > "${CACHE_DIR}/${key}.json" 2>/dev/null
}

# --- Billing API: get services list (with cache) ---
billing_get_services() {
    local cached
    cached=$(cache_get "billing_services")
    if [[ -n "$cached" ]]; then
        log_info "Billing catalog: from cache (TTL ${CACHE_TTL}s)"
        echo "$cached"
        return
    fi
    local token
    token=$(gcloud auth print-access-token 2>/dev/null)
    local result
    result=$(curl -sS --max-time 15 -H "Authorization: Bearer $token" \
        "https://cloudbilling.googleapis.com/v1/services?pageSize=500" 2>/dev/null)
    [[ -n "$result" ]] && cache_set "billing_services" "$result"
    echo "$result"
}

# --- Billing API: get SKUs for a service (with cache) ---
billing_get_skus() {
    local service_id="$1"
    local cached
    cached=$(cache_get "billing_skus_${service_id}")
    if [[ -n "$cached" ]]; then
        echo "$cached"
        return
    fi
    local token
    token=$(gcloud auth print-access-token 2>/dev/null)
    local result
    result=$(curl -sS --max-time 15 -H "Authorization: Bearer $token" \
        "https://cloudbilling.googleapis.com/v1/services/${service_id}/skus?pageSize=100" 2>/dev/null)
    [[ -n "$result" ]] && cache_set "billing_skus_${service_id}" "$result"
    echo "$result"
}

# --- Fetch quota for a single service (used when building bulk cache) ---
fetch_quota_for_service() {
    local service="$1"
    local project_num="$2"
    local consumer="projects/${project_num}"

    if command -v timeout &>/dev/null; then
        timeout "$QUOTA_TIMEOUT" gcloud beta services quota list --service="$service" \
            --consumer="$consumer" --format="json" 2>/dev/null || echo "[]"
    else
        gcloud beta services quota list --service="$service" \
            --consumer="$consumer" --format="json" 2>/dev/null || echo "[]"
    fi
}

# --- Get All Quotas: fetch quotas for all services upfront, then match with services ---
# Populates global quota_bulk_cache. Call before the main report loop.
# Usage: fetch_all_quotas PROJECT_NUM SERVICE1 SERVICE2 ...
fetch_all_quotas() {
    local project_num="$1"
    shift
    local services_to_fetch=("$@")

    # Try bulk fetch first (if API supports --project without --service)
    local all_quotas
    all_quotas=$(gcloud beta services quota list --project="$PROJECT_ID" --format="json" 2>/dev/null)

    if [[ -n "$all_quotas" ]] && echo "$all_quotas" | jq -e '.' &>/dev/null; then
        # Parse bulk response: group consumerQuotaMetrics by service name
        # Metric names: projects/N/services/SERVICE/consumerQuotaMetrics/...
        quota_bulk_cache=$(echo "$all_quotas" | jq -c '
            if type == "array" then . else [.] end |
            [.[] | .consumerQuotaMetrics? // . | if type == "array" then .[] else . end] |
            flatten |
            group_by(.name | split("/") | .[3]) |
            map({key: (.[0].name | split("/") | .[3]), value: .}) |
            from_entries
        ' 2>/dev/null)
        [[ -n "$quota_bulk_cache" && "$quota_bulk_cache" != "null" ]] && return
    fi

    # Fallback: fetch per-service for all services we will process
    # Use existing cache, only fetch services we don't have
    for svc in "${services_to_fetch[@]}"; do
        [[ -z "$svc" ]] && continue
        local cached
        cached=$(echo "$quota_bulk_cache" | jq -r -c --arg s "$svc" '.[$s] // empty' 2>/dev/null)
        if [[ -n "$cached" && "$cached" != "[]" && "$cached" != "null" ]]; then
            continue
        fi
        local data
        data=$(fetch_quota_for_service "$svc" "$project_num")
        quota_bulk_cache=$(echo "$quota_bulk_cache" | jq -c --arg s "$svc" --argjson d "$data" '.[$s] = $d' 2>/dev/null)
    done
}

# --- Get quota for service from bulk cache (lookup only - cache must be pre-populated) ---
# Sets global quota_result (do NOT use in subshell - call directly)
get_quota_for_service() {
    local service="$1"

    # Lookup from pre-populated bulk cache
    quota_result=$(echo "$quota_bulk_cache" | jq -r -c --arg s "$service" '.[$s] // []' 2>/dev/null)
    [[ -z "$quota_result" || "$quota_result" = "null" ]] && quota_result="[]"
}

# --- Extract unit price (USD) from SKU pricing ---
# Returns first non-zero tier price per base unit
get_sku_unit_price() {
    local sku_json="$1"
    local price
    price=$(echo "$sku_json" | jq -r '
        [.pricingInfo[0].pricingExpression.tieredRates[]? |
         ((.unitPrice.units | tonumber) + ((.unitPrice.nanos // 0) / 1000000000)) |
         select(. > 0)] | if length > 0 then .[0] else 0 end
    ' 2>/dev/null)
    echo "${price:-0}"
}

# --- Get usage unit from SKU ---
get_sku_usage_unit() {
    echo "$1" | jq -r '.pricingInfo[0].pricingExpression.usageUnit // "unknown"' 2>/dev/null
}

# --- Parse quota value from quota JSON ---
get_quota_value() {
    local quota_json="$1"
    echo "$quota_json" | jq -r '
        [.consumerQuotaLimits[]? | .quotaBuckets[0].effectiveLimit // empty] |
        if length > 0 then (.[0] | tostring) else "" end
    ' 2>/dev/null
}

# --- Main: build report data ---
build_report_data() {
    log_info "Fetching enabled services..."
    local enabled_services=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && enabled_services+=("$line")
    done < <(gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name)" 2>/dev/null)

    log_info "Fetching billing catalog..."
    local billing_services
    billing_services=$(billing_get_services)
    if ! echo "$billing_services" | jq -e '.services' &>/dev/null; then
        log_warn "Cloud Billing API: Ensure Cloud Billing API is enabled and you have cloud-billing.readonly."
        billing_services='{"services":[]}'
    fi

    local rows=""
    local project_num
    project_num=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null)

    # Build list of services we will process (enabled + billable)
    local services_to_process=()
    for api_service in "${enabled_services[@]}"; do
        [[ -z "$api_service" ]] && continue
        local dn
        dn=$(get_billing_display_name "$api_service")
        [[ -z "$dn" ]] && continue
        local sid
        sid=$(echo "$billing_services" | jq -r --arg d "$dn" '.services[] | select(.displayName == $d) | .serviceId' 2>/dev/null | head -1)
        [[ -z "$sid" || "$sid" = "null" ]] && continue
        services_to_process+=("$api_service")
    done

    # Get All Quotas first, then match with services
    log_info "Fetching all quotas..."
    quota_bulk_cache=$(cache_get "quota_${PROJECT_ID}_all" 2>/dev/null)
    [[ -z "$quota_bulk_cache" || "$quota_bulk_cache" = "null" ]] && quota_bulk_cache="{}"
    [[ "$quota_bulk_cache" = "" ]] && quota_bulk_cache="{}"
    fetch_all_quotas "$project_num" "${services_to_process[@]}"

    for api_service in "${enabled_services[@]}"; do
        [[ -z "$api_service" ]] && continue

        local display_name
        display_name=$(get_billing_display_name "$api_service")
        [[ -z "$display_name" ]] && continue

        local service_id
        service_id=$(echo "$billing_services" | jq -r --arg d "$display_name" '
            .services[] | select(.displayName == $d) | .serviceId
        ' 2>/dev/null | head -1)
        [[ -z "$service_id" || "$service_id" = "null" ]] && continue

        log_info "  $display_name ($api_service)..."

        local skus_json
        skus_json=$(billing_get_skus "$service_id")
        local sku_count
        sku_count=$(echo "$skus_json" | jq '.skus | length' 2>/dev/null || echo "0")
        [[ "${sku_count:-0}" -eq 0 ]] && continue

        quota_result="[]"
        get_quota_for_service "$api_service"
        local quota_json="${quota_result:-[]}"

        # Get first/main quota value for this service
        local quota_val
        quota_val=$(echo "$quota_json" | jq -r '
            [.. | .consumerQuotaLimits? | select(. != null) | .[] | .quotaBuckets[0].effectiveLimit // empty] |
            map(select(. != null)) | if length > 0 then (.[0] | tostring) else "" end
        ' 2>/dev/null)
        [[ "$quota_val" = "-1" ]] && quota_val="unlimited"

        # Process top SKUs (limit to avoid huge output)
        local idx=0
        while read -r sku; do
            [[ -z "$sku" || "$sku" = "null" ]] && continue
            [[ $idx -ge 5 ]] && break

            local sku_desc
            sku_desc=$(echo "$sku" | jq -r '.description // .skuId' 2>/dev/null | head -c 80 | tr '|' '-')
            local unit_price
            unit_price=$(get_sku_unit_price "$sku")
            local usage_unit
            usage_unit=$(get_sku_usage_unit "$sku")

            # Skip free or zero-price SKUs
            [[ -z "$unit_price" || "$unit_price" = "0" ]] && continue

            # Estimate daily: assume hourly -> *24, monthly -> /30, etc.
            local est_daily=""
            local suggested_quota=""
            local do_calc="no"
            [[ -n "$quota_val" && "$quota_val" != "N/A" && "$quota_val" != "unlimited" ]] && do_calc="yes"
            # usage_unit: h=hourly, GiBy/By=storage, request/1000=per-request APIs (Maps, Vision, etc.)
            if [[ "$do_calc" = "yes" ]]; then
                case "$usage_unit" in
                    *h|*Hour*) est_daily=$(echo "scale=2; $unit_price * 24 * ${quota_val}" | bc 2>/dev/null || echo "?") ;;
                    *GiBy|*By|*GB*) est_daily=$(echo "scale=2; $unit_price * ${quota_val} / 30" | bc 2>/dev/null || echo "?") ;;
                    *request*|*1000*|*1k*) est_daily=$(echo "scale=2; $unit_price * ${quota_val} / 1000 / 30" | bc 2>/dev/null || echo "?") ;;
                    *) est_daily=$(echo "scale=2; $unit_price * ${quota_val}" | bc 2>/dev/null || echo "?") ;;
                esac
            else
                est_daily="N/A"
            fi

            # Suggested quota: max units to stay within budget
            if [[ -n "$BUDGET_DAILY" && "$BUDGET_DAILY" != "0" && -n "$unit_price" && "$unit_price" != "0" ]]; then
                case "$usage_unit" in
                    *h|*Hour*) suggested_quota=$(echo "scale=0; $BUDGET_DAILY / ($unit_price * 24)" | bc 2>/dev/null || echo "-") ;;
                    *GiBy|*By|*GB*) suggested_quota=$(echo "scale=0; $BUDGET_DAILY * 30 / $unit_price" | bc 2>/dev/null || echo "-") ;;
                    *request*|*1000*|*1k*) suggested_quota=$(echo "scale=0; $BUDGET_DAILY * 1000 / $unit_price" | bc 2>/dev/null || echo "-") ;;
                    *) suggested_quota=$(echo "scale=0; $BUDGET_DAILY / $unit_price" | bc 2>/dev/null || echo "-") ;;
                esac
            fi
            [[ -z "$suggested_quota" ]] && suggested_quota="-"

            rows="${rows}
${PROJECT_ID}|${display_name}|${sku_desc}|${quota_val:-N/A}|${est_daily:-N/A}|${suggested_quota:-}|${unit_price}|${usage_unit}"
            ((idx++)) || true
        done < <(echo "$skus_json" | jq -c '.skus[]?' 2>/dev/null)
    done

    # Save bulk quota cache for next run
    [[ -n "$quota_bulk_cache" ]] && cache_set "quota_${PROJECT_ID}_all" "$quota_bulk_cache"

    echo "$rows"
}

# --- Format and output ---
main() {
    check_prerequisites

    log_info "Budget: \$${TARGET_BUDGET_USD}/month (~\$${BUDGET_DAILY}/day)"
    log_info "Project: $PROJECT_ID"

    local raw_rows
    raw_rows=$(build_report_data)

    # Sort by est. daily (col5) desc; when N/A, by 1/suggested so lower suggested = higher cost first
    local sorted
    sorted=$(echo "$raw_rows" | grep -v '^$' | while IFS='|' read -r a b c d e f g h; do
        local sortkey="0"
        [[ -n "$e" && "$e" != "N/A" && "$e" != "?" ]] && sortkey="$e"
        [[ "$sortkey" = "0" && -n "$f" && "$f" != "-" ]] && [[ "$f" =~ ^[0-9]+$ ]] && sortkey=$(echo "scale=2; 999999/$f" | bc 2>/dev/null || echo "0")
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$sortkey" "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"
    done | sort -t'|' -k1 -rn 2>/dev/null | cut -d'|' -f2-)
    [[ -z "$sorted" ]] && sorted=$(echo "$raw_rows" | grep -v '^$')

    # Build table header
    local header="Project|Service|SKU|Current Quota|Est. Price Daily (USD)|Suggested Quota|Unit Price|Unit"
    local table_content="$header
$sorted"

    # Save full report to file
    {
        echo "# GCP Quota & Billing Report"
        echo ""
        echo "**Project:** $PROJECT_ID"
        echo "**Target Budget:** \$${TARGET_BUDGET_USD} USD/month"
        echo "**Generated:** $(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
        echo ""
        echo "---"
        echo ""
        echo "| Project | Service | SKU | Current Quota | Est. Price Daily (USD) | Suggested Quota |"
        echo "|---------|---------|-----|---------------|------------------------|-----------------|"
        echo "$sorted" | while IFS='|' read -r proj svc sku quota est sugg _ _; do
            [[ -z "$proj" ]] && continue
            printf '| %s | %s | %s | %s | %s | %s |\n' "$proj" "$svc" "${sku}" "${quota:-N/A}" "${est:-N/A}" "${sugg:--}"
        done
    } > "$REPORT_FILE"

    # Print table to terminal (highlights)
    echo ""
    echo "=== Quota & Billing (sorted by Est. Price Daily) ==="
    echo ""
    printf "%-20s %-18s %-50s %12s %18s %14s\n" "Project" "Service" "SKU" "Quota" "Est.Daily $" "Suggested"
    echo "---------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "$sorted" | while IFS='|' read -r proj svc sku quota est sugg _ _; do
        [[ -z "$proj" ]] && continue
        printf "%-20s %-18s %-50s %12s %18s %14s\n" \
            "${proj:0:18}" "${svc:0:16}" "${sku:0:48}" "${quota:-N/A}" "${est:-N/A}" "${sugg:--}"
    done
    echo ""
    log_info "Full report: $REPORT_FILE"
}

main "$@"
