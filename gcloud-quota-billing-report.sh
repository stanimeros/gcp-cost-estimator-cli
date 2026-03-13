#!/usr/bin/env bash
#
# GCP Quota & Billing Report
# Table with project, service SKU, current quota, and quota units per $10/day.
# Processes all accessible GCP projects.
#
# Usage:
#   ./gcloud-quota-billing-report.sh
#

set -euo pipefail

# --- Configuration ---
REPORT_FILE="billing-report.md"
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
        "https://cloudbilling.googleapis.com/v1/services?pageSize=5000" 2>/dev/null)
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
# Preserves existing cached entries when gcloud fails for a service.
# Usage: fetch_all_quotas SERVICE1 SERVICE2 ...
fetch_all_quotas() {
    local services=("$@")
    # Start with existing cache so we keep data when gcloud fails
    local merged="${quota_bulk_cache:-{}}"
    [[ -z "$merged" || "$merged" = "null" ]] && merged="{}"
    for svc in "${services[@]}"; do
        [[ -z "$svc" ]] && continue
        local data
        if command -v timeout &>/dev/null; then
            data=$(timeout 30 gcloud beta quotas info list --service="$svc" --project="$PROJECT_ID" --format="json" 2>&1)
        else
            data=$(gcloud beta quotas info list --service="$svc" --project="$PROJECT_ID" --format="json" 2>&1)
        fi
        # Only merge when gcloud returns a non-empty array; preserve cached data when gcloud returns [] or fails
        if [[ -n "$data" ]] && echo "$data" | jq -e 'type == "array" and length > 0' &>/dev/null; then
            local new_merged
            new_merged=$(echo "$merged" | jq -c --arg s "$svc" --argjson d "$data" '.[$s] = $d' 2>/dev/null)
            [[ -n "$new_merged" ]] && merged="$new_merged"
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

# --- Main: build report data for a single project ---
# Usage: build_report_data PROJECT_ID
# Outputs: REPORT_STATS line followed by data rows
build_report_data() {
    local PROJECT_ID="$1"
    log_info "[$PROJECT_ID] Fetching enabled services..."
    local enabled_services=()
    local enabled_titles=()
    while IFS=$'\t' read -r name title; do
        [[ -n "$name" ]] || continue
        enabled_services+=("$name")
        enabled_titles+=("${title:-$name}")
    done < <(gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name,config.title)" 2>/dev/null)

    log_info "[$PROJECT_ID] Fetching billing catalog..."
    local billing_services
    billing_services=$(billing_get_services)
    if ! echo "$billing_services" | jq -e '.services' &>/dev/null; then
        log_warn "Cloud Billing API: Ensure Cloud Billing API is enabled and you have cloud-billing.readonly."
        billing_services='{"services":[]}'
    fi

    local rows=""
    local report_services=0 report_skus=0

    # Build list of services we will process (enabled + billable)
    local services_to_process=()
    for i in "${!enabled_services[@]}"; do
        local api_service="${enabled_services[$i]}"
        local dn="${enabled_titles[$i]}"
        [[ -z "$api_service" ]] && continue
        local sid
        local d_stripped="${dn% API}"
        sid=$(echo "$billing_services" | jq -r --arg d "$dn" --arg ds "$d_stripped" '
            .services[] | select(
                .displayName == $d or
                .displayName == $ds or
                (($ds == "Generative Language") and (.displayName == "Gemini API")) or
                ((.displayName | ascii_downcase) | startswith(($ds | ascii_downcase)))
            ) | .serviceId
        ' 2>/dev/null | head -1)
        [[ -z "$sid" || "$sid" = "null" ]] && continue
        services_to_process+=("$api_service")
    done

    # Fetch all quotas up front
    log_info "[$PROJECT_ID] Fetching all quotas..."
    quota_bulk_cache=$(cache_get "quota_${PROJECT_ID}_all" 2>/dev/null)
    if [[ -z "$quota_bulk_cache" || "$quota_bulk_cache" = "null" || "$quota_bulk_cache" = "" ]]; then
        quota_bulk_cache=$(cat "${CACHE_DIR}/quota_${PROJECT_ID}_all.json" 2>/dev/null || true)
    fi
    [[ -z "$quota_bulk_cache" || "$quota_bulk_cache" = "null" ]] && quota_bulk_cache="{}"
    [[ "$quota_bulk_cache" = "" ]] && quota_bulk_cache="{}"
    fetch_all_quotas "${services_to_process[@]}"

    for i in "${!enabled_services[@]}"; do
        local api_service="${enabled_services[$i]}"
        local display_name="${enabled_titles[$i]}"
        [[ -z "$api_service" ]] && continue

        local service_id
        local d_stripped_inner="${display_name% API}"
        service_id=$(echo "$billing_services" | jq -r --arg d "$display_name" --arg ds "$d_stripped_inner" '
            .services[] | select(
                .displayName == $d or
                .displayName == $ds or
                (($ds == "Generative Language") and (.displayName == "Gemini API")) or
                ((.displayName | ascii_downcase) | startswith(($ds | ascii_downcase)))
            ) | .serviceId
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

        # Get first quota with a value from dimensionsInfos; fallback to first quota's name when no value
        # Output: val|name|unit|refresh (single jq pass for consistency)
        local quota_extract tmpq
        tmpq=$(mktemp 2>/dev/null || echo "/tmp/q_$$_$RANDOM")
        printf '%s' "$quota_json" > "$tmpq" 2>/dev/null
        quota_extract=$(jq -r '
            . as $input |
            ([.[]? | . as $q |
              ([.dimensionsInfos[]?.details.value? | select(. != null and . != "")] | .[0]) as $v |
              if $v != null then
                ($v | tostring) + "|" + ($q.quotaDisplayName // $q.metricDisplayName // $q.quotaId // "Quota") + "|" + ($q.metricUnit // "") + "|" + ($q.refreshInterval // "")
              else empty end
            ] | .[0]) as $first |
            if ($first != null and $first != "") then $first
            else ($input | .[0]? | "|" + (.quotaDisplayName // .metricDisplayName // .quotaId // "Quota") + "||" + (.refreshInterval // ""))
            end
        ' "$tmpq" 2>/dev/null)
        rm -f "$tmpq"
        local quota_val quota_name quota_unit refresh_interval
        quota_val="" quota_name="" quota_unit="" refresh_interval=""
        if [[ -n "$quota_extract" ]]; then
            quota_val=$(echo "$quota_extract" | cut -d'|' -f1)
            quota_name=$(echo "$quota_extract" | cut -d'|' -f2)
            quota_unit=$(echo "$quota_extract" | cut -d'|' -f3)
            refresh_interval=$(echo "$quota_extract" | cut -d'|' -f4)
            [[ -z "$quota_val" && "$quota_extract" = "|"* ]] && quota_name=$(echo "$quota_extract" | cut -d'|' -f2)
        fi
        if [[ -n "$refresh_interval" ]]; then
            case "$refresh_interval" in
                minute) quota_name="${quota_name} per minute" ;;
                day) quota_name="${quota_name} per day" ;;
                second) quota_name="${quota_name} per second" ;;
                *) quota_name="${quota_name} per ${refresh_interval}" ;;
            esac
        fi
        [[ "$quota_val" = "-1" ]] && quota_val="unlimited"
        [[ "$quota_val" = "9223372036854775807" ]] && quota_val="unlimited"

        # Aggregate SKUs per service
        local sku_descs=()
        local best_est_daily="N/A"
        # quota_per_10: units you can consume for $10/day (from most expensive SKU)
        local best_quota_per_10="N/A"
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

            # Estimate daily cost at current quota
            local est_daily=""
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
                est_daily="N/A"
            fi

            if [[ "$do_calc" = "yes" ]] && ! units_compatible "${quota_unit:-}" "${quota_name:-}" "$usage_unit"; then
                est_daily="N/A"
            fi
            local qname_lower
            qname_lower=$(echo "${quota_name:-}" | tr '[:upper:]' '[:lower:]')
            if [[ "$qname_lower" = *"request"* || "$qname_lower" = *"per minute"* || "$qname_lower" = *"per second"* || "$qname_lower" = *"createcapacity"* ]]; then
                [[ "$do_calc" = "yes" ]] && est_daily="N/A"
            fi
            if [[ "$est_daily" =~ ^[0-9.]+$ ]] && (( $(echo "$est_daily > 100000" | bc 2>/dev/null || echo 0) )); then
                est_daily="N/A"
            fi

            # Quota per $10/day: how many units $10 buys per day (using same unit conversion as est_daily)
            local quota_per_10=""
            if [[ -n "$unit_price" && "$unit_price" != "0" ]]; then
                # Only compute when units are compatible (same logic as est_daily)
                local compatible="yes"
                ! units_compatible "${quota_unit:-}" "${quota_name:-}" "$usage_unit" && compatible="no"
                [[ "$qname_lower" = *"request"* || "$qname_lower" = *"per minute"* || "$qname_lower" = *"per second"* || "$qname_lower" = *"createcapacity"* ]] && compatible="no"
                if [[ "$compatible" = "yes" ]]; then
                    case "$usage_unit" in
                        *h|*Hour*) quota_per_10=$(echo "scale=0; 10 / ($unit_price * 24)" | bc 2>/dev/null || echo "N/A") ;;
                        *GiBy|*By|*GB*) quota_per_10=$(echo "scale=0; 10 * 30 / $unit_price" | bc 2>/dev/null || echo "N/A") ;;
                        *request*|*1000*|*1k*) quota_per_10=$(echo "scale=0; 10 * 1000 / $unit_price" | bc 2>/dev/null || echo "N/A") ;;
                        *) quota_per_10=$(echo "scale=0; 10 / $unit_price" | bc 2>/dev/null || echo "N/A") ;;
                    esac
                fi
            fi
            [[ -z "$quota_per_10" ]] && quota_per_10="N/A"

            if [[ "$est_daily" != "N/A" && "$est_daily" != "" && "$est_daily" != "?" ]]; then
                [[ "$best_est_daily" = "N/A" ]] && best_est_daily="$est_daily"
            fi
            # quota_per_10 from most expensive SKU (lowest value = tightest budget)
            if [[ "$quota_per_10" != "N/A" && "$quota_per_10" =~ ^[0-9]+$ ]]; then
                if [[ "$best_quota_per_10" = "N/A" ]] || [[ "$quota_per_10" -lt "$best_quota_per_10" ]]; then
                    best_quota_per_10="$quota_per_10"
                fi
            fi
            ((idx++)) || true
        done < <(echo "$skus_json" | jq -c '.skus[]?' 2>/dev/null)

        [[ ${#sku_descs[@]} -eq 0 ]] && continue
        report_services=$((report_services + 1))
        report_skus=$((report_skus + ${#sku_descs[@]}))
        local sku_combined
        sku_combined=$(IFS=', '; echo "${sku_descs[*]}")
        if [[ ${#sku_combined} -gt 80 ]]; then
            sku_combined="${sku_combined:0:77}..."
        fi
        [[ -z "$quota_name" ]] && quota_name="Quota"
        rows="${rows}
${PROJECT_ID}|${api_service}|${quota_name}|${sku_combined}|${quota_val:-N/A}|${best_quota_per_10}|${best_est_daily:-N/A}|0|"
    done

    # Save bulk quota cache for next run
    [[ -n "$quota_bulk_cache" ]] && cache_set "quota_${PROJECT_ID}_all" "$quota_bulk_cache"

    echo "REPORT_STATS|${report_services}|${report_skus}"
    echo "$rows"
}

# --- Format and output ---
main() {
    check_prerequisites

    # Collect all accessible project IDs
    local all_projects=()
    while read -r pid; do
        [[ -n "$pid" ]] && all_projects+=("$pid")
    done < <(gcloud projects list --format="value(projectId)" 2>/dev/null)

    if [[ ${#all_projects[@]} -eq 0 ]]; then
        log_error "No accessible projects found."
        exit 1
    fi

    log_info "Found ${#all_projects[@]} project(s): ${all_projects[*]}"

    local all_rows=""
    local total_services=0 total_skus=0

    for pid in "${all_projects[@]}"; do
        local raw_output
        raw_output=$(build_report_data "$pid")

        local stat_services stat_skus data_rows first_line
        first_line=$(echo "$raw_output" | head -1)
        if [[ "$first_line" = REPORT_STATS* ]]; then
            IFS='|' read -r _ stat_services stat_skus <<< "$first_line"
            data_rows=$(echo "$raw_output" | tail -n +2)
        else
            stat_services=0
            stat_skus=0
            data_rows="$raw_output"
        fi
        total_services=$((total_services + stat_services))
        total_skus=$((total_skus + stat_skus))
        all_rows="${all_rows}
${data_rows}"
    done

    # Sort all rows: by est price desc (primary), then by current quota desc (secondary)
    local sorted
    sorted=$(echo "$all_rows" | grep -v '^$' | while IFS='|' read -r proj svc qname sku quota qper10 est _ _; do
        local sortkey_est="0"
        [[ -n "$est" && "$est" != "N/A" && "$est" != "?" ]] && sortkey_est="$est"
        if [[ "$sortkey_est" = "0" && -n "$qper10" && "$qper10" != "N/A" ]] && [[ "$qper10" =~ ^[0-9]+$ ]]; then
            sortkey_est=$(echo "scale=2; 999999/$qper10" | bc 2>/dev/null || echo "0")
        fi
        local sortkey_quota="0"
        [[ "$quota" = "unlimited" ]] && sortkey_quota="9223372036854775807"
        [[ "$quota" =~ ^[0-9]+$ ]] && sortkey_quota="$quota"
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$sortkey_est" "$sortkey_quota" "$proj" "$svc" "$qname" "$sku" "$quota" "$qper10" "$est" ""
    done | sort -t'|' -k1 -rn -k2 -rn 2>/dev/null | cut -d'|' -f3-)
    [[ -z "$sorted" ]] && sorted=$(echo "$all_rows" | grep -v '^$')

    # Save full report to file
    {
        echo "# GCP Quota & Billing Report"
        echo ""
        echo "**Projects:** ${all_projects[*]}"
        echo "**Generated:** $(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
        echo ""
        echo "---"
        echo ""
        echo "**Services** $total_services, **SKUs** $total_skus"
        echo ""
        echo "| Project | Service | Quota name | SKU(s) | Current quota | Quota per \$10/day | Est. price daily |"
        echo "|---------|---------|------------|--------|---------------|-------------------|------------------|"
        echo "$sorted" | while IFS='|' read -r proj svc qname sku quota qper10 est _ _; do
            [[ -z "$svc" ]] && continue
            printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$proj" "$svc" "$qname" "${sku}" "${quota:-N/A}" "${qper10:-N/A}" "${est:-N/A}"
        done
    } > "$REPORT_FILE"

    # Print table to terminal
    echo ""
    echo "=== Quota & Billing (sorted by Est. Price Daily, then Current quota) ==="
    echo ""
    printf "%-25s %-38s %-22s %-42s %12s %16s %16s\n" "Project" "Service" "Quota name" "SKU(s)" "Quota" "Per \$10/day" "Est.Daily"
    echo "-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
    echo "$sorted" | while IFS='|' read -r proj svc qname sku quota qper10 est _ _; do
        [[ -z "$svc" ]] && continue
        printf "%-25s %-38s %-22s %-42s %12s %16s %16s\n" \
            "${proj:0:23}" "${svc:0:36}" "${qname:0:20}" "${sku:0:40}" "${quota:-N/A}" "${qper10:-N/A}" "${est:-N/A}"
    done
    echo ""
    log_info "Full report: $REPORT_FILE"
}

main "$@"
