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
    # Ensure gcloud beta component is installed (required for quota list)
    if ! gcloud components list --only-local-state --filter="id:beta" --format="value(id)" 2>/dev/null | grep -q "beta"; then
        log_info "Installing gcloud beta component (output below)..."
        gcloud components install beta --quiet 2>&1
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

# --- Get All Quotas: fetch per-service (gcloud beta quotas info list --service= was removed) ---
# Uses gcloud beta quotas info list --service=X per service. Populates global quota_bulk_cache.
# Usage: fetch_all_quotas SERVICE1 SERVICE2 ...
fetch_all_quotas() {
    local services=("$@")
    local merged="{}"
    for svc in "${services[@]}"; do
        [[ -z "$svc" ]] && continue
        local data
        if command -v timeout &>/dev/null; then
            data=$(timeout 30 gcloud beta quotas info list --service="$svc" --project="$PROJECT_ID" --format="json" 2>&1)
        else
            data=$(gcloud beta quotas info list --service="$svc" --project="$PROJECT_ID" --format="json" 2>&1)
        fi
        if [[ -n "$data" ]] && echo "$data" | jq -e 'type == "array"' &>/dev/null; then
            merged=$(echo "$merged" | jq -c --arg s "$svc" --argjson d "$data" '.[$s] = $d' 2>/dev/null)
        fi
    done
    quota_bulk_cache="$merged"
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
    local enabled_titles=()
    while IFS=$'\t' read -r name title; do
        [[ -n "$name" ]] || continue
        enabled_services+=("$name")
        enabled_titles+=("${title:-$name}")
    done < <(gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name,config.title)" 2>/dev/null)

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
    for i in "${!enabled_services[@]}"; do
        local api_service="${enabled_services[$i]}"
        local dn="${enabled_titles[$i]}"
        [[ -z "$api_service" ]] && continue
        local sid
        sid=$(echo "$billing_services" | jq -r --arg d "$dn" '.services[] | select(.displayName == $d) | .serviceId' 2>/dev/null | head -1)
        [[ -z "$sid" || "$sid" = "null" ]] && continue
        services_to_process+=("$api_service")
    done

    # Get All Quotas first, then match with services
    log_info "Fetching all quotas (gcloud output below)..."
    quota_bulk_cache=$(cache_get "quota_${PROJECT_ID}_all" 2>/dev/null)
    [[ -z "$quota_bulk_cache" || "$quota_bulk_cache" = "null" ]] && quota_bulk_cache="{}"
    [[ "$quota_bulk_cache" = "" ]] && quota_bulk_cache="{}"
    fetch_all_quotas "${services_to_process[@]}"

    for i in "${!enabled_services[@]}"; do
        local api_service="${enabled_services[$i]}"
        local display_name="${enabled_titles[$i]}"
        [[ -z "$api_service" ]] && continue

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

        # Get first/main quota value: support both old (consumerQuotaLimits) and new (dimensionsInfos.details.value) QuotaInfo format
        local quota_val
        quota_val=$(echo "$quota_json" | jq -r '
            [.. | (.consumerQuotaLimits? | select(. != null) | .[] | .quotaBuckets[0].effectiveLimit // empty),
             (.. | .dimensionsInfos? | select(. != null) | .[] | .details.value? // empty)] |
            map(select(. != null and . != "")) | if length > 0 then (.[0] | tostring) else "" end
        ' 2>/dev/null)
        # GCP uses -1 or 9223372036854775807 (2^63-1) for unlimited quotas
        [[ "$quota_val" = "-1" ]] && quota_val="unlimited"
        [[ "$quota_val" = "9223372036854775807" ]] && quota_val="unlimited"

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
