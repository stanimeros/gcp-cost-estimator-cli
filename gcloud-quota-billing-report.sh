#!/usr/bin/env bash
#
# GCP Quota & Billing Report
# Table with project, service SKU, current quota, and quota units per target $/day.
# Processes all accessible GCP projects.
#
# Usage:
#   ./gcloud-quota-billing-report.sh [--full]
#   --full    Include "safe to ignore" services (default: hide them)
#

set -euo pipefail

# --- Configuration ---
REPORT_FILE="billing-report.md"
# Cache: in script folder (.cache/). Delete .cache/ to refetch.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/.cache}"
# Target daily budget (USD); set via prompt or BUDGET_DAILY env
BUDGET_DAILY="${BUDGET_DAILY:-}"

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
# Returns cached content if present, else empty. Usage: cached="$(cache_get "key")"
cache_get() {
    local key="$1"
    local file="${CACHE_DIR}/${key}.json"
    [[ -f "$file" ]] || return 1
    cat "$file" 2>/dev/null
}

cache_set() {
    local key="$1"
    local content="$2"
    mkdir -p "$CACHE_DIR"
    echo "$content" > "${CACHE_DIR}/${key}.json" 2>/dev/null
}

# --- Billing API: get services list (with cache) ---
billing_get_services() {
    local cached
    cached=$(cache_get "billing_services")
    if [[ -n "$cached" ]]; then
        log_info "Billing catalog: from cache"
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
# TMP_QUOTA_CACHE must be pre-loaded with persistent cache from ${CACHE_DIR}/quota_${PROJECT_ID}_all.json.
# Fetches only missing services in parallel (up to PARALLEL_QUOTA_JOBS).
# Usage: fetch_all_quotas PROJECT_ID SERVICE1 SERVICE2 ...
PARALLEL_QUOTA_JOBS="${PARALLEL_QUOTA_JOBS:-8}"
fetch_all_quotas() {
    local project_id="$1"; shift
    local services=("${@+"$@"}")
    local missing=()
    for svc in "${services[@]+"${services[@]}"}"; do
        [[ -z "$svc" ]] && continue
        if ! jq -e --arg s "$svc" 'has($s)' "$TMP_QUOTA_CACHE" &>/dev/null; then
            missing+=("$svc")
        fi
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    local tmpdir
    tmpdir=$(mktemp -d)

    # Fetch missing services in parallel; each writes JSON to ${tmpdir}/${svc}.json
    for svc in "${missing[@]}"; do
        (
            local data
            if command -v timeout &>/dev/null; then
                data=$(timeout 30 gcloud beta quotas info list --service="$svc" --project="$project_id" --format="json" 2>/dev/null)
            else
                data=$(gcloud beta quotas info list --service="$svc" --project="$project_id" --format="json" 2>/dev/null)
            fi
            if [[ -n "$data" ]] && echo "$data" | jq -e 'type == "array" and length > 0' &>/dev/null; then
                printf '%s' "$data" > "${tmpdir}/${svc}.json"
            fi
        ) &
    done
    wait

    # Merge fetched results into TMP_QUOTA_CACHE (sequential merge is fast)
    local tmp_new
    tmp_new=$(mktemp)
    for svc in "${missing[@]}"; do
        [[ -f "${tmpdir}/${svc}.json" ]] || continue
        local data
        data=$(cat "${tmpdir}/${svc}.json" 2>/dev/null)
        [[ -z "$data" ]] && continue
        jq -c --arg s "$svc" --argjson d "$data" '.[$s] = $d' "$TMP_QUOTA_CACHE" > "$tmp_new" 2>/dev/null \
            && mv "$tmp_new" "$TMP_QUOTA_CACHE"
    done
    rm -f "$tmp_new"
    rm -rf "$tmpdir"
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

        # Aggregate SKUs per service (once; reused for all quotas)
        local sku_descs=()
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

            local budget="${BUDGET_DAILY:-10}"
            local budget_mo
            budget_mo=$(echo "$budget * 30" | bc -l 2>/dev/null)
            local quota_per_budget=""
            if [[ -n "$unit_price" && "$unit_price" != "0" ]]; then
                local raw_val=""
                local u="$usage_unit"
                case "$u" in
                    h|*Hour*)            raw_val=$(echo "$budget / ($unit_price * 24)" | bc -l 2>/dev/null) ;;
                    GiBy.mo|TiBy.mo|MiBy.mo|mo) raw_val=$(echo "$budget_mo / $unit_price" | bc -l 2>/dev/null) ;;
                    GiBy.h|GBy.h)        raw_val=$(echo "$budget / ($unit_price * 24)" | bc -l 2>/dev/null) ;;
                    GiBy.s|GBy.s)        raw_val=$(echo "$budget / ($unit_price * 86400)" | bc -l 2>/dev/null) ;;
                    GiBy.d)              raw_val=$(echo "$budget / $unit_price" | bc -l 2>/dev/null) ;;
                    GiBy|GBy)            raw_val=$(echo "$budget_mo / $unit_price" | bc -l 2>/dev/null) ;;
                    TiBy)                raw_val=$(echo "$budget_mo / $unit_price" | bc -l 2>/dev/null) ;;
                    MiBy)                raw_val=$(echo "$budget_mo * 1024 / $unit_price" | bc -l 2>/dev/null) ;;
                    min)                 raw_val=$(echo "$budget / ($unit_price * 1440)" | bc -l 2>/dev/null) ;;
                    s|ms)                raw_val=$(echo "$budget / ($unit_price * 86400)" | bc -l 2>/dev/null) ;;
                    count|1)             raw_val=$(echo "$budget / $unit_price" | bc -l 2>/dev/null) ;;
                    *request*|*1000*|*1k*) raw_val=$(echo "$budget * 1000 / $unit_price" | bc -l 2>/dev/null) ;;
                    *)                   raw_val=$(echo "$budget / $unit_price" | bc -l 2>/dev/null) ;;
                esac
                [[ -n "$raw_val" ]] && quota_per_budget=$(printf "%.0f" "$raw_val" 2>/dev/null || echo "")
            fi
            quota_per_budget=$(echo "$quota_per_budget" | tr -d ' \n\r')
            [[ -z "$quota_per_budget" || "$quota_per_budget" = "0" ]] && quota_per_budget="N/A"

            local q_int
            q_int=$(echo "$quota_per_budget" | sed 's/^\([0-9]*\).*/\1/' | tr -d '\n')
            if [[ -n "$q_int" && "$q_int" =~ ^[0-9]+$ && "$q_int" -gt 0 ]]; then
                if [[ "$best_quota_per_10" = "N/A" ]] || [[ "$q_int" -lt "$best_quota_per_10" ]]; then
                    best_quota_per_10="$q_int"
                fi
            fi
            ((idx++)) || true
        done < <(jq -c '.skus[]?' "$tmp_skus" 2>/dev/null)

        rm -f "$tmp_skus"
        [[ ${#sku_descs[@]} -eq 0 ]] && continue

        local sku_combined
        sku_combined=$(IFS=', '; echo "${sku_descs[*]}")
        [[ ${#sku_combined} -gt 80 ]] && sku_combined="${sku_combined:0:77}..."

        # Output one row per quota (all quotas for this service)
        local tmpq rows_added=0
        tmpq=$(mktemp 2>/dev/null || echo "/tmp/q_$$_$RANDOM")
        printf '%s' "$quota_json" > "$tmpq" 2>/dev/null
        while IFS='|' read -r quota_val quota_name quota_unit refresh_interval is_fixed; do
            [[ -z "$quota_name" ]] && quota_name="Quota"
            [[ -z "$quota_val" && "${quota_val:-x}" != "x" ]] && quota_val=""
            if [[ -n "$refresh_interval" ]]; then
                local suffix=""
                case "$refresh_interval" in
                    minute) suffix="per minute" ;;
                    day) suffix="per day" ;;
                    second) suffix="per second" ;;
                    *) suffix="per ${refresh_interval}" ;;
                esac
                local qname_lower
                qname_lower=$(echo "$quota_name" | tr '[:upper:]' '[:lower:]')
                [[ -n "$suffix" && "$qname_lower" != *"$suffix"* ]] && quota_name="${quota_name} ${suffix}"
            fi
            [[ "$quota_val" = "null" || "$quota_val" = "Null" ]] && quota_val="0"
            [[ "$quota_val" = "-1" ]] && quota_val="unlimited"
            [[ "$quota_val" = "9223372036854775807" ]] && quota_val="unlimited"
            is_non_adjustable "$api_service" "$quota_name" "$is_fixed" && continue
            # Hide when quota_per_budget > current_quota (budget buys more than quota allows; quota is not the bottleneck)
            if [[ -n "$best_quota_per_10" && "$best_quota_per_10" != "N/A" && "$best_quota_per_10" =~ ^[0-9]+$ ]] && \
               [[ "$quota_val" != "unlimited" && -n "$quota_val" && "$quota_val" =~ ^[0-9]+$ ]]; then
                [[ "$best_quota_per_10" -gt "$quota_val" ]] && continue
            fi
            report_services=$((report_services + 1))
            rows_added=$((rows_added + 1))
            rows="${rows}
${api_service}|${quota_name}|${sku_combined}|${quota_val:-N/A}|${best_quota_per_10}|"
        done < <(jq -r '
            . as $input |
            if ($input | type) == "array" then
                ($input[]? | . as $q |
                  ([.dimensionsInfos[]?.details.value? | select(. != null and . != "")] | .[0]) as $v |
                  (($v | tostring) // "") + "|" + ($q.quotaDisplayName // $q.metricDisplayName // $q.quotaId // "Quota") + "|" + ($q.metricUnit // "") + "|" + ($q.refreshInterval // "") + "|" + (if ($q.isFixed // false) then "1" else "0" end)
                )
            else empty
            end
        ' "$tmpq" 2>/dev/null)
        rm -f "$tmpq"
        [[ $rows_added -gt 0 ]] && report_skus=$((report_skus + ${#sku_descs[@]}))
    done

    # Save quota cache for next run — copy TMP_QUOTA_CACHE to disk if valid and non-empty
    if jq -e 'type == "object" and length > 0' "$TMP_QUOTA_CACHE" &>/dev/null; then
        mkdir -p "$CACHE_DIR"
        cp "$TMP_QUOTA_CACHE" "${CACHE_DIR}/quota_${PROJECT_ID}_all.json"
    fi

    echo "REPORT_STATS|${report_services}|${report_skus}"
    echo "$rows"
}

# --- Truncate for width-safe table output ---
truncate_cell() {
    local s="$1"
    local max="${2:-50}"
    [[ ${#s} -le $max ]] && { echo "$s"; return; }
    echo "${s:0:$((max - 3))}..."
}

# --- Format SKU for multi-line (wrap to ~half width via <br>) ---
format_sku_cell() {
    local sku="$1"
    local max_per_line=38
    local max_lines=3
    local result=""
    local count=0
    while IFS= read -r part; do
        [[ $count -ge $max_lines ]] && { result="${result}<br>..."; break; }
        part="${part#"${part%%[![:space:]]*}"}"
        part="${part%"${part##*[![:space:]]}"}"
        [[ -z "$part" ]] && continue
        [[ ${#part} -gt $max_per_line ]] && part="${part:0:$((max_per_line - 3))}..."
        [[ -n "$result" ]] && result="${result}<br>"
        result="${result}${part}"
        ((count++)) || true
    done < <(echo "$sku" | tr ',' '\n')
    echo "${result:-$sku}"
}

# --- Check if quota is non-adjustable (user cannot change it; skip from report) ---
is_non_adjustable() {
    local svc="$1"
    local qname="$2"
    local is_fixed="$3"
    [[ "$is_fixed" = "1" || "$is_fixed" = "true" ]] && return 0
    case "$svc" in
        storage.googleapis.com) [[ "$qname" =~ [Aa]nywhere[[:space:]]Cache ]] && return 0 ;;
    esac
    return 1
}

# --- Check if row is "safe to ignore" (management plane, plumbing, high-limit safety) ---
is_safe_to_ignore() {
    local svc="$1"
    local qname="$2"
    case "$svc" in
        cloudtrace.googleapis.com)     [[ "$qname" =~ [Cc]onfiguration ]] && return 0 ;;
        eventarc.googleapis.com)       [[ "$qname" =~ [Mm]utation ]] && return 0 ;;
        cloudbuild.googleapis.com)     [[ "$qname" =~ [Oo]ther[[:space:]]API ]] && return 0 ;;
        bigqueryreservation.googleapis.com) [[ "$qname" =~ [Cc]reateCapacityCommitment ]] && return 0 ;;
        storage-component.googleapis.com) return 0 ;;
        containerregistry.googleapis.com) return 0 ;;
        monitoring.googleapis.com)    [[ "$qname" =~ [Aa]ctive[[:space:]]Alert ]] && return 0 ;;
        pubsub.googleapis.com)        [[ "$qname" =~ [Aa]cks ]] && [[ "$qname" =~ [Mm]odify ]] && return 0 ;;
        bigquery.googleapis.com)       [[ "$qname" =~ [Aa]lloyDB ]] && [[ "$qname" =~ [Ff]ederated ]] && return 0 ;;
        bigquerystorage.googleapis.com) return 0 ;;
        bigquerydatatransfer.googleapis.com) return 0 ;;
        recaptchaenterprise.googleapis.com) return 0 ;;
    esac
    return 1
}

# --- Sort rows: need-attention first (by quota_per_10 asc), safe-to-ignore last ---
sort_rows() {
    local rows="$1"
    local need_attention safe_to_ignore
    need_attention=""
    safe_to_ignore=""
    while IFS='|' read -r svc qname sku quota qper10 _; do
        [[ -z "$svc" ]] && continue
        local line="$svc|$qname|$sku|$quota|$qper10"
        if is_safe_to_ignore "$svc" "$qname"; then
            safe_to_ignore="${safe_to_ignore}${line}"$'\n'
        else
            need_attention="${need_attention}${line}"$'\n'
        fi
    done < <(echo "$rows" | grep -v '^$')

    local sortkey sortkey_quota
    local sort_need
    sort_need=$(echo "$need_attention" | grep -v '^$' | while IFS='|' read -r svc qname sku quota qper10 _; do
        sortkey="999999"
        [[ -n "$qper10" && "$qper10" != "N/A" && "$qper10" =~ ^[0-9]+$ && "$qper10" -gt 0 ]] && sortkey="$qper10"
        sortkey_quota="0"
        [[ "$quota" = "unlimited" ]] && sortkey_quota="9223372036854775807"
        [[ "$quota" =~ ^[0-9]+$ ]] && sortkey_quota="$quota"
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$sortkey" "$sortkey_quota" "$svc" "$qname" "$sku" "$quota" "$qper10"
    done | sort -t'|' -k1 -n -k2 -rn 2>/dev/null | cut -d'|' -f3-)

    local sort_safe
    sort_safe=$(echo "$safe_to_ignore" | grep -v '^$' | while IFS='|' read -r svc qname sku quota qper10 _; do
        sortkey="999999"
        [[ -n "$qper10" && "$qper10" != "N/A" && "$qper10" =~ ^[0-9]+$ && "$qper10" -gt 0 ]] && sortkey="$qper10"
        sortkey_quota="0"
        [[ "$quota" = "unlimited" ]] && sortkey_quota="9223372036854775807"
        [[ "$quota" =~ ^[0-9]+$ ]] && sortkey_quota="$quota"
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$sortkey" "$sortkey_quota" "$svc" "$qname" "$sku" "$quota" "$qper10"
    done | sort -t'|' -k1 -n -k2 -rn 2>/dev/null | cut -d'|' -f3-)

    if [[ "${SHOW_SAFE_TO_IGNORE:-0}" = "1" ]]; then
        { echo "$sort_need"; echo "$sort_safe"; } | grep -v '^$'
    else
        echo "$sort_need" | grep -v '^$'
    fi
}

# --- Format and output ---
main() {
    SHOW_SAFE_TO_IGNORE=0
    for arg in "$@"; do
        [[ "$arg" = "--full" ]] && SHOW_SAFE_TO_IGNORE=1
    done
    [[ "$SHOW_SAFE_TO_IGNORE" = "1" ]] && log_info "Including safe-to-ignore services (--full)"

    check_prerequisites

    # Ask for target daily budget
    if [[ -z "${BUDGET_DAILY}" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Target daily budget (USD) [10]: " BUDGET_DAILY
        fi
        BUDGET_DAILY="${BUDGET_DAILY:-10}"
    fi
    if ! [[ "$BUDGET_DAILY" =~ ^[0-9]+\.?[0-9]*$ ]] || [[ "$(echo "$BUDGET_DAILY > 0" | bc -l 2>/dev/null)" -eq 0 ]]; then
        log_error "Invalid budget. Use a positive number (e.g. 10 or 50)."
        exit 1
    fi
    log_info "Target: \$${BUDGET_DAILY}/day"

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

    local total_quotas=0 total_services=0 total_skus=0

    # Start report file (only lists billing-enabled projects)
    {
        echo "# GCP Quota & Billing Report"
        echo ""
        echo "**Target:** \$${BUDGET_DAILY}/day | **Projects:** ${billed_projects[*]}"
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
        total_skus=$((total_skus + stat_skus))

        local sorted
        sorted=$(sort_rows "$data_rows")
        local stat_quotas
        stat_quotas=$(echo "$sorted" | grep -c . 2>/dev/null || echo 0)
        local stat_services
        stat_services=$(echo "$sorted" | cut -d'|' -f1 | sort -u | grep -c . 2>/dev/null || echo 0)
        total_quotas=$((total_quotas + stat_quotas))
        total_services=$((total_services + stat_services))

        # Append per-project section to report file
        {
            echo "## $pid"
            echo ""
            echo "**Quotas** $stat_quotas, **Services** $stat_services, **SKUs** $stat_skus"
            echo ""
            echo "| Service | Quota name | SKU(s) | Current quota | Quota per \$${BUDGET_DAILY}/day |"
            echo "|---------|------------|--------|---------------|-------------------|"
            echo "$sorted" | while IFS='|' read -r svc qname sku quota qper10 _; do
                [[ -z "$svc" ]] && continue
                local svc_out qname_out
                svc_out=$(truncate_cell "$svc" 42)
                qname_out=$(truncate_cell "$qname" 50)
                if ! is_safe_to_ignore "$svc" "$qname"; then
                    svc_out="**${svc_out}**"
                    qname_out="**${qname_out}**"
                fi
                printf '| %s | %s | %s | %s | %s |\n' \
                    "$svc_out" \
                    "$qname_out" \
                    "$(format_sku_cell "$sku")" \
                    "${quota:-N/A}" \
                    "${qper10:-N/A}"
            done
            echo ""
        } >> "$REPORT_FILE"

        # Print per-project table to terminal
        echo ""
        echo "=== $pid (need attention first, safe to ignore last) ==="
        echo ""
        printf "%-38s %-22s %-42s %12s %16s\n" "Service" "Quota name" "SKU(s)" "Quota" "Per \$${BUDGET_DAILY}/day"
        echo "-------------------------------------------------------------------------------------------------------------------"
        echo "$sorted" | while IFS='|' read -r svc qname sku quota qper10 _; do
            [[ -z "$svc" ]] && continue
            printf "%-38s %-22s %-42s %12s %16s\n" \
                "${svc:0:36}" "${qname:0:20}" "${sku:0:40}" "${quota:-N/A}" "${qper10:-N/A}"
        done
    done

    # Append summary footer
    {
        echo "---"
        echo ""
        echo "**Total quotas** $total_quotas, **Total services** $total_services, **Total SKUs** $total_skus"
    } >> "$REPORT_FILE"

    echo ""
    log_info "Full report: $REPORT_FILE"
}

main "$@"
