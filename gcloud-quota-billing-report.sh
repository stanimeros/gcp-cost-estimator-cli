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

# --- Check if Quota unit and SKU unit are compatible for cost estimation ---
# Quota: Bytes/By/GiBy/MiBy + SKU: GiBy.mo/GiBy/By → Match
# Quota: Requests/1 (count) + SKU: request/1000 → Match
# Quota: Requests + SKU: Storage → No match (N/A)
units_compatible() {
    local quota_unit="$1"
    local quota_name="$2"
    local sku_usage_unit="$3"
    local q_unit_lower sku_lower qname_lower
    q_unit_lower=$(echo "${quota_unit:-}" | tr '[:upper:]' '[:lower:]')
    sku_lower=$(echo "${sku_usage_unit:-}" | tr '[:upper:]' '[:lower:]')
    qname_lower=$(echo "${quota_name:-}" | tr '[:upper:]' '[:lower:]')

    # Quota is storage/data (bytes)
    if [[ "$q_unit_lower" =~ ^(by|giby|miby|tiby|kiby|kb|mb|gb|tb)$ ]] || \
       [[ "$q_unit_lower" = *"by"* && "$q_unit_lower" != *"request"* ]]; then
        # SKU must be storage: GiBy, By, GiBy.mo, etc.
        if [[ "$sku_lower" = *"giby"* || "$sku_lower" = *"by"* || "$sku_lower" = *"gb"* || "$sku_lower" = *"miby"* ]]; then
            return 0  # Match
        fi
        return 1  # Quota=storage, SKU=other → No match
    fi

    # Quota is requests/count (metricUnit "1" or name has "request")
    if [[ "$q_unit_lower" = "1" ]] || [[ "$qname_lower" = *"request"* ]] || [[ "$q_unit_lower" = *"request"* ]]; then
        # SKU must be request-based
        if [[ "$sku_lower" = *"request"* || "$sku_lower" = *"1000"* || "$sku_lower" = *"1k"* ]]; then
            return 0  # Match
        fi
        return 1  # Quota=requests, SKU=storage etc → No match
    fi

    # Quota is time-based (e.g. slots per hour) - metricUnit "1" with slot-related name
    if [[ "$q_unit_lower" = "1" ]] && [[ "$qname_lower" = *"slot"* ]]; then
        if [[ "$sku_lower" = *"h"* || "$sku_lower" = *"hour"* ]]; then
            return 0
        fi
        return 1
    fi

    # Unknown quota unit: be permissive (allow calculation) to avoid false N/As
    return 0
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
    local report_services=0 report_skus=0
    local project_num
    project_num=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)' 2>/dev/null)

    # Build list of services we will process (enabled + billable)
    local services_to_process=()
    for i in "${!enabled_services[@]}"; do
        local api_service="${enabled_services[$i]}"
        local dn="${enabled_titles[$i]}"
        [[ -z "$api_service" ]] && continue
        local sid
        # Match: exact displayName, or with " API" suffix stripped (e.g. "BigQuery API" -> "BigQuery")
        sid=$(echo "$billing_services" | jq -r --arg d "$dn" '
            .services[] | select(.displayName == $d or .displayName == ($d | sub(" API$"; ""))) | .serviceId
        ' 2>/dev/null | head -1)
        [[ -z "$sid" || "$sid" = "null" ]] && continue
        services_to_process+=("$api_service")
    done

    # Get All Quotas first, then match with services
    log_info "Fetching all quotas (gcloud output below)..."
    quota_bulk_cache=$(cache_get "quota_${PROJECT_ID}_all" 2>/dev/null)
    [[ -z "$quota_bulk_cache" || "$quota_bulk_cache" = "null" ]] && quota_bulk_cache="{}"
    [[ "$quota_bulk_cache" = "" ]] && quota_bulk_cache="{}"
    fetch_all_quotas "${services_to_process[@]}"

    # Budget per service: daily budget split equally across billable services
    local num_services=${#services_to_process[@]}
    local budget_per_service
    if [[ "$num_services" -gt 0 ]]; then
        budget_per_service=$(echo "scale=4; $BUDGET_DAILY / $num_services" | bc 2>/dev/null || echo "$BUDGET_DAILY")
        [[ "$num_services" -gt 1 ]] && log_info "Budget split: \$${BUDGET_DAILY}/day total ÷ ${num_services} services = \$${budget_per_service}/day per service"
    else
        budget_per_service="$BUDGET_DAILY"
    fi

    for i in "${!enabled_services[@]}"; do
        local api_service="${enabled_services[$i]}"
        local display_name="${enabled_titles[$i]}"
        [[ -z "$api_service" ]] && continue

        local service_id
        service_id=$(echo "$billing_services" | jq -r --arg d "$display_name" '
            .services[] | select(.displayName == $d or .displayName == ($d | sub(" API$"; ""))) | .serviceId
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

        # Get first/main quota value, name, and unit: support QuotaInfo format (metricUnit for unit matching)
        local quota_val quota_name quota_unit
        quota_val=$(echo "$quota_json" | jq -r '
            [.[]? | select(.dimensionsInfos[]?.details.value? != null and .dimensionsInfos[]?.details.value? != "") |
             .dimensionsInfos[0].details.value | tostring] | if length > 0 then .[0] else "" end
        ' 2>/dev/null)
        quota_name=$(echo "$quota_json" | jq -r '
            [.[]? | select(.dimensionsInfos[]?.details.value? != null and .dimensionsInfos[]?.details.value? != "") |
             .quotaDisplayName // .metricDisplayName // .quotaId // "Quota"] | if length > 0 then .[0] else "" end
        ' 2>/dev/null)
        quota_unit=$(echo "$quota_json" | jq -r '
            [.[]? | select(.dimensionsInfos[]?.details.value? != null and .dimensionsInfos[]?.details.value? != "") |
             .metricUnit // ""] | if length > 0 then .[0] else "" end
        ' 2>/dev/null)
        # GCP uses -1 or 9223372036854775807 (2^63-1) for unlimited quotas
        [[ "$quota_val" = "-1" ]] && quota_val="unlimited"
        [[ "$quota_val" = "9223372036854775807" ]] && quota_val="unlimited"

        # Aggregate SKUs per service (one row per service with all SKU names combined)
        local sku_descs=()
        local best_est_daily="N/A"
        local best_suggested="-"
        local idx=0
        while read -r sku; do
            [[ -z "$sku" || "$sku" = "null" ]] && continue
            [[ $idx -ge 20 ]] && break

            local sku_desc
            sku_desc=$(echo "$sku" | jq -r '.description // .skuId' 2>/dev/null | head -c 80 | tr '|' '-')
            local unit_price
            unit_price=$(get_sku_unit_price "$sku")
            local usage_unit
            usage_unit=$(get_sku_usage_unit "$sku")

            # Skip free or zero-price SKUs
            [[ -z "$unit_price" || "$unit_price" = "0" ]] && continue

            sku_descs+=("$sku_desc")

            # Estimate daily: assume hourly -> *24, monthly -> /30, etc.
            local est_daily=""
            local suggested_quota=""
            local do_calc="no"
            [[ -n "$quota_val" && "$quota_val" != "N/A" && "$quota_val" != "unlimited" ]] && do_calc="yes"
            if [[ "$do_calc" = "yes" ]]; then
                case "$usage_unit" in
                    *h|*Hour*) est_daily=$(echo "scale=2; $unit_price * 24 * ${quota_val}" | bc 2>/dev/null || echo "?") ;;
                    *GiBy|*By|*GB*) est_daily=$(echo "scale=2; $unit_price * ${quota_val} / 30" | bc 2>/dev/null || echo "?") ;;
                    *request*|*1000*|*1k*) est_daily=$(echo "scale=2; $unit_price * ${quota_val} / 1000 / 30" | bc 2>/dev/null || echo "?") ;;
                    *) est_daily=$(echo "scale=2; $unit_price * ${quota_val}" | bc 2>/dev/null || echo "?") ;;
                esac
            else
                est_daily="unlimited"
            fi

            # Unit match: Quota (By/GiBy) + SKU (GiBy.mo) = Match. Quota (Requests) + SKU (Storage) = N/A
            if [[ "$do_calc" = "yes" ]] && ! units_compatible "${quota_unit:-}" "${quota_name:-}" "$usage_unit"; then
                est_daily="N/A"
            fi
            # Rate-limit quotas (e.g. "Requests for X", "per minute") or quota/SKU mismatch → N/A
            local qname_lower
            qname_lower=$(echo "${quota_name:-}" | tr '[:upper:]' '[:lower:]')
            if [[ "$qname_lower" = *"request"* || "$qname_lower" = *"per minute"* || "$qname_lower" = *"per second"* || "$qname_lower" = *"createcapacity"* ]]; then
                [[ "$do_calc" = "yes" ]] && est_daily="N/A"
            fi
            # Sanity cap: est > 100000 suggests quota/SKU mismatch
            if [[ "$est_daily" =~ ^[0-9.]+$ ]] && (( $(echo "$est_daily > 100000" | bc 2>/dev/null || echo 0) )); then
                est_daily="N/A"
            fi

            # Suggested quota: max units to stay within this service's budget share (daily budget / num services)
            if [[ -n "$budget_per_service" && "$budget_per_service" != "0" && -n "$unit_price" && "$unit_price" != "0" ]]; then
                case "$usage_unit" in
                    *h|*Hour*) suggested_quota=$(echo "scale=0; $budget_per_service / ($unit_price * 24)" | bc 2>/dev/null || echo "-") ;;
                    *GiBy|*By|*GB*) suggested_quota=$(echo "scale=0; $budget_per_service * 30 / $unit_price" | bc 2>/dev/null || echo "-") ;;
                    *request*|*1000*|*1k*) suggested_quota=$(echo "scale=0; $budget_per_service * 1000 / $unit_price" | bc 2>/dev/null || echo "-") ;;
                    *) suggested_quota=$(echo "scale=0; $budget_per_service / $unit_price" | bc 2>/dev/null || echo "-") ;;
                esac
            fi
            [[ -z "$suggested_quota" ]] && suggested_quota="-"

            # Track best est_daily (unlimited takes precedence; else first numeric) and best_suggested (min = from most expensive SKU)
            if [[ "$est_daily" = "unlimited" ]]; then
                best_est_daily="unlimited"
            elif [[ "$best_est_daily" != "unlimited" ]] && [[ "$est_daily" != "N/A" && "$est_daily" != "" && "$est_daily" != "?" ]]; then
                [[ "$best_est_daily" = "N/A" ]] && best_est_daily="$est_daily"
            fi
            # Suggested from most expensive SKU (highest unit_price → lowest suggested) = safest budget limit
            if [[ -n "$suggested_quota" && "$suggested_quota" != "-" ]] && [[ "$suggested_quota" =~ ^[0-9]+$ ]]; then
                if [[ "$best_suggested" = "-" ]] || [[ "$suggested_quota" -lt "$best_suggested" ]]; then
                    best_suggested="$suggested_quota"
                fi
            fi
            ((idx++)) || true
        done < <(echo "$skus_json" | jq -c '.skus[]?' 2>/dev/null)

        [[ ${#sku_descs[@]} -eq 0 ]] && continue
        report_services=$((report_services + 1))
        report_skus=$((report_skus + ${#sku_descs[@]}))
        local sku_combined
        sku_combined=$(IFS=', '; echo "${sku_descs[*]}")
        [[ "$quota_val" = "unlimited" && "$best_est_daily" = "N/A" ]] && best_est_daily="unlimited"
        [[ -z "$quota_name" ]] && quota_name="Quota"
        rows="${rows}
${api_service}|${quota_name}|${sku_combined}|${quota_val:-N/A}|${best_suggested:-}|${best_est_daily:-N/A}|0|"
    done

    # Save bulk quota cache for next run
    [[ -n "$quota_bulk_cache" ]] && cache_set "quota_${PROJECT_ID}_all" "$quota_bulk_cache"

    echo "REPORT_STATS|${report_services}|${report_skus}|${BUDGET_DAILY}|${budget_per_service}"
    echo "$rows"
}

# --- Format and output ---
main() {
    check_prerequisites

    log_info "Budget: \$${TARGET_BUDGET_USD}/month (~\$${BUDGET_DAILY}/day)"
    log_info "Project: $PROJECT_ID"

    local raw_output
    raw_output=$(build_report_data)

    # Parse stats from first line (REPORT_STATS|services|skus|budget_daily|budget_per_service)
    local stat_services stat_skus stat_budget_daily stat_budget_per_service data_rows
    local first_line
    first_line=$(echo "$raw_output" | head -1)
    if [[ "$first_line" = REPORT_STATS* ]]; then
        IFS='|' read -r _ stat_services stat_skus stat_budget_daily stat_budget_per_service <<< "$first_line"
        data_rows=$(echo "$raw_output" | tail -n +2)
    else
        stat_services=0
        stat_skus=0
        stat_budget_daily="$BUDGET_DAILY"
        stat_budget_per_service="$BUDGET_DAILY"
        data_rows="$raw_output"
    fi

    # Format budget for summary (1 decimal)
    local budget_daily_fmt budget_per_fmt
    budget_daily_fmt=$(echo "scale=1; $stat_budget_daily/1" | bc 2>/dev/null || echo "$stat_budget_daily")
    budget_per_fmt=$(echo "scale=1; $stat_budget_per_service/1" | bc 2>/dev/null || echo "$stat_budget_per_service")

    # Sort: unlimited est price first, then by est price desc (bigger first). Cols: service|quota_name|sku|quota|suggested|est|_
    local sorted
    sorted=$(echo "$data_rows" | grep -v '^$' | while IFS='|' read -r svc qname sku quota sugg est _ _; do
        local sortkey="0"
        [[ "$est" = "unlimited" ]] && sortkey="999999999"
        [[ "$sortkey" = "0" && -n "$est" && "$est" != "N/A" && "$est" != "?" ]] && sortkey="$est"
        [[ "$sortkey" = "0" && -n "$sugg" && "$sugg" != "-" ]] && [[ "$sugg" =~ ^[0-9]+$ ]] && sortkey=$(echo "scale=2; 999999/$sugg" | bc 2>/dev/null || echo "0")
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$sortkey" "$svc" "$qname" "$sku" "$quota" "$sugg" "$est" "0" ""
    done | sort -t'|' -k1 -rn 2>/dev/null | cut -d'|' -f2-)
    [[ -z "$sorted" ]] && sorted=$(echo "$data_rows" | grep -v '^$')

    # Build table header (no Project; Service = api name for console matching)
    local header="Service|Quota name|SKU(s)|Current quota|Suggested quota|Est. price daily"
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
        echo "**Services** $stat_services, **SKUs** $stat_skus, **Daily budget** \$${budget_daily_fmt}, **Per service daily budget** \$${budget_per_fmt}"
        echo ""
        echo "| Service | Quota name | SKU(s) | Current quota | Suggested quota | Est. price daily |"
        echo "|---------|------------|--------|---------------|-----------------|------------------|"
        echo "$sorted" | while IFS='|' read -r svc qname sku quota sugg est _ _; do
            [[ -z "$svc" ]] && continue
            printf '| %s | %s | %s | %s | %s | %s |\n' "$svc" "$qname" "${sku}" "${quota:-N/A}" "${sugg:--}" "${est:-N/A}"
        done
    } > "$REPORT_FILE"

    # Print table to terminal (highlights)
    echo ""
    echo "=== Quota & Billing (sorted by Est. Price Daily) ==="
    echo ""
    printf "%-40s %-25s %-45s %12s %12s %18s\n" "Service" "Quota name" "SKU(s)" "Quota" "Suggested" "Est.Daily"
    echo "---------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "$sorted" | while IFS='|' read -r svc qname sku quota sugg est _ _; do
        [[ -z "$svc" ]] && continue
        printf "%-40s %-25s %-45s %12s %12s %18s\n" \
            "${svc:0:38}" "${qname:0:23}" "${sku:0:43}" "${quota:-N/A}" "${sugg:--}" "${est:-N/A}"
    done
    echo ""
    log_info "Full report: $REPORT_FILE"
}

main "$@"
