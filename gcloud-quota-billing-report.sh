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

# Global temp files reused across calls within a project (set by build_report_data)
TMP_QUOTA_CACHE=""   # quota JSON object for current project
TMP_BILLING=""       # billing services catalog

# --- Get All Quotas: fetch per-service into TMP_QUOTA_CACHE file.
# Skips services already present in the file (cache hit = no gcloud call).
# Usage: fetch_all_quotas PROJECT_ID SERVICE1 SERVICE2 ...
fetch_all_quotas() {
    local project_id="$1"; shift
    local services=("${@+"$@"}")
    local tmp_new
    tmp_new=$(mktemp)
    for svc in "${services[@]+"${services[@]}"}"; do
        [[ -z "$svc" ]] && continue
        # Skip if already in cache file
        if jq -e --arg s "$svc" 'has($s)' "$TMP_QUOTA_CACHE" &>/dev/null; then
            continue
        fi
        local data
        if command -v timeout &>/dev/null; then
            data=$(timeout 30 gcloud beta quotas info list --service="$svc" --project="$project_id" --format="json" 2>&1)
        else
            data=$(gcloud beta quotas info list --service="$svc" --project="$project_id" --format="json" 2>&1)
        fi
        if [[ -n "$data" ]] && echo "$data" | jq -e 'type == "array" and length > 0' &>/dev/null; then
            jq -c --arg s "$svc" --argjson d "$data" '.[$s] = $d' "$TMP_QUOTA_CACHE" > "$tmp_new" 2>/dev/null \
                && mv "$tmp_new" "$TMP_QUOTA_CACHE"
        fi
    done
    rm -f "$tmp_new"
}

# --- Get quota for service from TMP_QUOTA_CACHE file ---
# Sets global quota_result (do NOT use in subshell - call directly)
get_quota_for_service() {
    quota_result=$(jq -r -c --arg s "$1" '.[$s] // []' "$TMP_QUOTA_CACHE" 2>/dev/null)
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


# --- Main: build report data for a single project ---
# Usage: build_report_data PROJECT_ID
# Outputs: REPORT_STATS line followed by data rows
build_report_data() {
    local PROJECT_ID="$1"

    # Set up persistent temp files for this project (reused by all helper functions)
    TMP_BILLING=$(mktemp)
    TMP_QUOTA_CACHE=$(mktemp)
    # Ensure cleanup on exit/error
    trap 'rm -f "$TMP_BILLING" "$TMP_QUOTA_CACHE"' RETURN

    log_info "[$PROJECT_ID] Fetching enabled services..."
    local enabled_services=()
    local enabled_titles=()
    while IFS=$'\t' read -r name title; do
        [[ -n "$name" ]] || continue
        enabled_services+=("$name")
        enabled_titles+=("${title:-$name}")
    done < <(gcloud services list --enabled --project="$PROJECT_ID" --format="value(config.name,config.title)" 2>/dev/null)

    log_info "[$PROJECT_ID] Fetching billing catalog..."
    local billing_services_raw
    billing_services_raw=$(billing_get_services)
    echo "$billing_services_raw" > "$TMP_BILLING"
    if ! jq -e '.services' "$TMP_BILLING" &>/dev/null; then
        log_warn "[$PROJECT_ID] Failed to fetch billing catalog. Check gcloud auth and cloud-billing.readonly permission."
        echo '{"services":[]}' > "$TMP_BILLING"
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
        sid=$(jq -r --arg d "$dn" --arg ds "$d_stripped" '
            .services[] | select(
                .displayName == $d or
                .displayName == $ds or
                (($ds == "Generative Language") and (.displayName == "Gemini API")) or
                ((.displayName | ascii_downcase) | startswith(($ds | ascii_downcase)))
            ) | .serviceId
        ' "$TMP_BILLING" 2>/dev/null | head -1)
        [[ -z "$sid" || "$sid" = "null" ]] && continue
        services_to_process+=("$api_service")
    done

    # Load quota cache from disk into TMP_QUOTA_CACHE file
    log_info "[$PROJECT_ID] Fetching all quotas..."
    local quota_cache_file="${CACHE_DIR}/quota_${PROJECT_ID}_all.json"
    if [[ -f "$quota_cache_file" ]] && jq -e 'type == "object"' "$quota_cache_file" &>/dev/null; then
        cp "$quota_cache_file" "$TMP_QUOTA_CACHE"
    else
        echo '{}' > "$TMP_QUOTA_CACHE"
    fi
    fetch_all_quotas "$PROJECT_ID" "${services_to_process[@]+"${services_to_process[@]}"}"

    for i in "${!enabled_services[@]}"; do
        local api_service="${enabled_services[$i]}"
        local display_name="${enabled_titles[$i]}"
        [[ -z "$api_service" ]] && continue

        local service_id
        local d_stripped_inner="${display_name% API}"
        service_id=$(jq -r --arg d "$display_name" --arg ds "$d_stripped_inner" '
            .services[] | select(
                .displayName == $d or
                .displayName == $ds or
                (($ds == "Generative Language") and (.displayName == "Gemini API")) or
                ((.displayName | ascii_downcase) | startswith(($ds | ascii_downcase)))
            ) | .serviceId
        ' "$TMP_BILLING" 2>/dev/null | head -1)
        [[ -z "$service_id" || "$service_id" = "null" ]] && continue

        log_info "  $display_name ($api_service)..."

        local skus_json
        skus_json=$(billing_get_skus "$service_id")
        local tmp_skus
        tmp_skus=$(mktemp)
        printf '%s' "$skus_json" > "$tmp_skus"
        local sku_count
        sku_count=$(jq '.skus | length' "$tmp_skus" 2>/dev/null || echo "0")
        [[ "${sku_count:-0}" -eq 0 ]] && { rm -f "$tmp_skus"; continue; }

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

            # Quota per $10/day: how many units $10 buys per day (based purely on SKU price+unit)
            # usageUnit values seen in practice: h, GiBy, GiBy.mo, GiBy.h, GiBy.s, GiBy.d,
            #   TiBy, MiBy, GBy.h, count, mo, min, s, ms, request, 1000, 1k
            local quota_per_10=""
            if [[ -n "$unit_price" && "$unit_price" != "0" ]]; then
                local u="$usage_unit"
                case "$u" in
                    h|*Hour*)            quota_per_10=$(echo "scale=0; 10 / ($unit_price * 24)" | bc 2>/dev/null) ;;       # per hour → hours/day
                    GiBy.mo|TiBy.mo|MiBy.mo|mo) quota_per_10=$(echo "scale=0; 10 * 30 / $unit_price" | bc 2>/dev/null) ;;  # per month → $10/day = $300/mo
                    GiBy.h|GBy.h)        quota_per_10=$(echo "scale=0; 10 / ($unit_price * 24)" | bc 2>/dev/null) ;;       # per GiBy-hour → GiBy that fit in $10/day
                    GiBy.s|GBy.s)        quota_per_10=$(echo "scale=0; 10 / ($unit_price * 86400)" | bc 2>/dev/null) ;;    # per GiBy-second
                    GiBy.d)              quota_per_10=$(echo "scale=0; 10 / $unit_price" | bc 2>/dev/null) ;;              # per GiBy-day
                    GiBy|GBy)            quota_per_10=$(echo "scale=0; 10 * 30 / $unit_price" | bc 2>/dev/null) ;;         # per GiBy (storage, monthly)
                    TiBy)                quota_per_10=$(echo "scale=0; 10 * 30 / $unit_price" | bc 2>/dev/null) ;;         # per TiBy
                    MiBy)                quota_per_10=$(echo "scale=0; 10 * 30 * 1024 / $unit_price" | bc 2>/dev/null) ;;  # per MiBy → more units
                    min)                 quota_per_10=$(echo "scale=0; 10 / ($unit_price * 1440)" | bc 2>/dev/null) ;;     # per minute → minutes/day
                    s|ms)                quota_per_10=$(echo "scale=0; 10 / ($unit_price * 86400)" | bc 2>/dev/null) ;;    # per second
                    count|1)             quota_per_10=$(echo "scale=0; 10 / $unit_price" | bc 2>/dev/null) ;;              # per item/count
                    *request*|*1000*|*1k*) quota_per_10=$(echo "scale=0; 10 * 1000 / $unit_price" | bc 2>/dev/null) ;;    # per 1000 requests
                    *)                   quota_per_10=$(echo "scale=0; 10 / $unit_price" | bc 2>/dev/null) ;;              # fallback
                esac
            fi
            quota_per_10=$(echo "$quota_per_10" | tr -d ' \n\r')
            [[ -z "$quota_per_10" || "$quota_per_10" = "0" ]] && quota_per_10="N/A"

            # quota_per_10 from most expensive SKU (lowest value = tightest budget)
            # Accept integers; strip decimals (bc can output 27272.000)
            local q10_int
            q10_int=$(echo "$quota_per_10" | sed 's/^\([0-9]*\).*/\1/' | tr -d '\n')
            if [[ -n "$q10_int" && "$q10_int" =~ ^[0-9]+$ && "$q10_int" -gt 0 ]]; then
                if [[ "$best_quota_per_10" = "N/A" ]] || [[ "$q10_int" -lt "$best_quota_per_10" ]]; then
                    best_quota_per_10="$q10_int"
                fi
            fi
            ((idx++)) || true
        done < <(jq -c '.skus[]?' "$tmp_skus" 2>/dev/null)

        rm -f "$tmp_skus"
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
${api_service}|${quota_name}|${sku_combined}|${quota_val:-N/A}|${best_quota_per_10}|"
    done

    # Save quota cache for next run — copy TMP_QUOTA_CACHE to disk if valid and non-empty
    if jq -e 'type == "object" and length > 0' "$TMP_QUOTA_CACHE" &>/dev/null; then
        mkdir -p "$CACHE_DIR"
        cp "$TMP_QUOTA_CACHE" "${CACHE_DIR}/quota_${PROJECT_ID}_all.json"
    fi

    echo "REPORT_STATS|${report_services}|${report_skus}"
    echo "$rows"
}

# --- Sort rows by quota_per_10 asc (most expensive first), then quota desc ---
sort_rows() {
    local rows="$1"
    local sorted
    sorted=$(echo "$rows" | grep -v '^$' | while IFS='|' read -r svc qname sku quota qper10 _; do
        local sortkey="999999"
        [[ -n "$qper10" && "$qper10" != "N/A" && "$qper10" =~ ^[0-9]+$ && "$qper10" -gt 0 ]] && sortkey="$qper10"
        local sortkey_quota="0"
        [[ "$quota" = "unlimited" ]] && sortkey_quota="9223372036854775807"
        [[ "$quota" =~ ^[0-9]+$ ]] && sortkey_quota="$quota"
        printf '%s|%s|%s|%s|%s|%s|\n' "$sortkey" "$sortkey_quota" "$svc" "$qname" "$sku" "$quota" "$qper10"
    done | sort -t'|' -k1 -n -k2 -rn 2>/dev/null | cut -d'|' -f3-)
    echo "$sorted"
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

    # Filter to billing-enabled projects up front
    local billed_projects=()
    for pid in "${all_projects[@]}"; do
        local billing_enabled
        billing_enabled=$(gcloud beta billing projects describe "$pid" --format="value(billingEnabled)" 2>/dev/null)
        if [[ "$billing_enabled" = "True" ]]; then
            billed_projects+=("$pid")
        else
            log_info "[$pid] Billing not enabled, skipping."
        fi
    done

    if [[ ${#billed_projects[@]} -eq 0 ]]; then
        log_error "No projects with billing enabled found."
        exit 1
    fi

    log_info "Processing ${#billed_projects[@]} billing-enabled project(s): ${billed_projects[*]}"

    local total_services=0 total_skus=0

    # Start report file (only lists billing-enabled projects)
    {
        echo "# GCP Quota & Billing Report"
        echo ""
        echo "**Projects:** ${billed_projects[*]}"
        echo "**Generated:** $(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
        echo ""
        echo "---"
        echo ""
    } > "$REPORT_FILE"

    for pid in "${billed_projects[@]}"; do

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

        local sorted
        sorted=$(sort_rows "$data_rows")

        # Append per-project section to report file
        {
            echo "## $pid"
            echo ""
            echo "**Services** $stat_services, **SKUs** $stat_skus"
            echo ""
            echo "| Service | Quota name | SKU(s) | Current quota | Quota per \$10/day |"
            echo "|---------|------------|--------|---------------|-------------------|"
            echo "$sorted" | while IFS='|' read -r svc qname sku quota qper10 _; do
                [[ -z "$svc" ]] && continue
                printf '| %s | %s | %s | %s | %s |\n' "$svc" "$qname" "${sku}" "${quota:-N/A}" "${qper10:-N/A}"
            done
            echo ""
        } >> "$REPORT_FILE"

        # Print per-project table to terminal
        echo ""
        echo "=== $pid (sorted by Quota per \$10/day, most expensive first) ==="
        echo ""
        printf "%-38s %-22s %-42s %12s %16s\n" "Service" "Quota name" "SKU(s)" "Quota" "Per \$10/day"
        echo "-------------------------------------------------------------------------------------------------------------------"
        echo "$sorted" | while IFS='|' read -r svc qname sku quota qper10 _; do
            [[ -z "$svc" ]] && continue
            printf "%-38s %-22s %-42s %12s %16s\n" \
                "${svc:0:36}" "${qname:0:20}" "${sku:0:40}" "${quota:-N/A}" "${qper10:-N/A}"
        done
    done

    # Append summary footer to report
    {
        echo "---"
        echo ""
        echo "**Total services** $total_services, **Total SKUs** $total_skus"
    } >> "$REPORT_FILE"

    echo ""
    log_info "Full report: $REPORT_FILE"
}

main "$@"
