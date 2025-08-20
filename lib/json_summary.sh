# lib/json_summary.sh
# Provides: write_summary_json <out_json> <results_log> <skip_log> <rg> <location> <series_filter> <max_parallel> <created_vms_file>
# Notes:
# - Does not count SKIPs as VMs "with tests".
# - Calculates success/completion rate.
# - If jq is available, adds details (good/bad/skips), series_stats and policy_failures.
# - If RUN_ID exists in the environment, includes it and also writes summary-${RUN_ID}.json alongside the alias summary.json (if out_json == artifacts/summary.json).

write_summary_json() {
  local OUT_JSON="${1:?out_json}"
  local RES_LOG="${2:?results_log}"
  local SKIP_LOG="${3:?skip_log}"
  local RG="${4:-}"
  local LOCATION="${5:-}"
  local SERIES_FILTER="${6:-all}"
  local MAX_PARALLEL="${7:-1}"
  local CREATED_VMS_FILE="${8:-}"

  local ART_DIR; ART_DIR="$(dirname "$OUT_JSON")"
  mkdir -p "$ART_DIR"

  # --- base counters ---
  GOOD_CNT=$(awk -F'|' '/^GOOD\|/{c++} END{print c+0}' "$RES_LOG" 2>/dev/null)
  BAD_CNT=$(awk -F'|'  '/^BAD\|/{c++}  END{print c+0}' "$RES_LOG"  2>/dev/null)
  DONE_CNT=$((GOOD_CNT + BAD_CNT))

  # VMs with results (excludes SKIPs)
  local VM_RESULTS_LIST VM_SKIPS_LIST
  if [[ -f "$RES_LOG" ]]; then
    VM_RESULTS_LIST=$(awk -F'[| ]' '/^(GOOD|BAD)\|/ {
      for (i=1; i<=NF; i++) if ($i ~ /^vm=/) { split($i,a,"="); print a[2] }
    }' "$RES_LOG" | sed '/^$/d' | sort -u)
  else
    VM_RESULTS_LIST=""
  fi
  if [[ -f "$SKIP_LOG" ]]; then
    VM_SKIPS_LIST=$(awk -F'[| ]' '/^SKIP\|/ {
      for (i=1; i<=NF; i++) if ($i ~ /^vm=/) { split($i,a,"="); print a[2] }
    }' "$SKIP_LOG" | sed '/^$/d' | sort -u)
  else
    VM_SKIPS_LIST=""
  fi
  TOTAL_VMS=$(printf "%s\n" "$VM_RESULTS_LIST" | sed '/^$/d' | wc -l | tr -d ' ')
  TOTAL_SKIPS=$(printf "%s\n" "$VM_SKIPS_LIST" | sed '/^$/d' | wc -l | tr -d ' ')

  # rates
  local SUCCESS_RATE COMPLETION_RATE
  if [[ "$DONE_CNT" -gt 0 ]]; then
    SUCCESS_RATE=$(awk -v g="$GOOD_CNT" -v d="$DONE_CNT" 'BEGIN{printf "%.0f", (g*100.0)/d}')
  else
    SUCCESS_RATE=0
  fi
  if [[ "$TOTAL_VMS" -gt 0 && "$DONE_CNT" -gt 0 ]]; then
    COMPLETION_RATE=100
  else
    COMPLETION_RATE=0
  fi

  # if jq is not available, output basic JSON
  if ! command -v jq >/dev/null 2>&1; then
    cat >"$OUT_JSON" <<JSON
{
  "run_id": "${RUN_ID:-}",
  "resource_group": "$RG",
  "location": "$LOCATION",
  "filters": { "series": "$SERIES_FILTER", "max_parallel": $MAX_PARALLEL },
  "key_statistics": {
    "success_rate": $SUCCESS_RATE,
    "total_vms": $TOTAL_VMS,
    "critical_skips": 0,
    "policy_failures": $BAD_CNT,
    "completion_rate": $COMPLETION_RATE,
    "skipped_combos": $TOTAL_SKIPS
  },
  "totals": { "GOOD": $GOOD_CNT, "BAD": $BAD_CNT, "SKIP": $TOTAL_SKIPS, "DONE": $DONE_CNT }
}
JSON
  else
  # build details with jq
    local GOOD_DETAILS BAD_DETAILS SKIP_DETAILS TMP_JSON EXPECTED_TESTS SERIES_STATS POLICY_FAILS
    GOOD_DETAILS="[]" ; BAD_DETAILS="[]" ; SKIP_DETAILS="[]"
    if [[ -f "$RES_LOG" ]]; then
      GOOD_DETAILS=$(awk -F'|' '/^GOOD\|/{
        vm=""; test=""; detail="";
        for(i=1;i<=NF;i++){
          if($i ~ /^vm=/){split($i,a,"="); vm=a[2]}
          else if($i ~ /^test=/){split($i,a,"="); test=a[2]}
          else if($i ~ /^detail=/){sub(/^detail=/,"",$i); detail=$i}
        }
        gsub("\"","\\\"",detail);
        printf("{\"vm\":\"%s\",\"test\":\"%s\",\"detail\":\"%s\"}\n", vm, test, detail)
      }' "$RES_LOG" | jq -s '.')
      BAD_DETAILS=$(awk -F'|' '/^BAD\|/{
        vm=""; test=""; detail="";
        for(i=1;i<=NF;i++){
          if($i ~ /^vm=/){split($i,a,"="); vm=a[2]}
          else if($i ~ /^test=/){split($i,a,"="); test=a[2]}
          else if($i ~ /^detail=/){sub(/^detail=/,"",$i); detail=$i}
        }
        gsub("\"","\\\"",detail);
        printf("{\"vm\":\"%s\",\"test\":\"%s\",\"detail\":\"%s\"}\n", vm, test, detail)
      }' "$RES_LOG" | jq -s '.')
    fi
    if [[ -f "$SKIP_LOG" ]]; then
      SKIP_DETAILS=$(awk -F'|' '/^SKIP\|/{
        vm=""; test=""; series=""; type=""; size=""; reason="";
        for(i=1;i<=NF;i++){
          if($i ~ /^vm=/){split($i,a,"="); vm=a[2]}
          else if($i ~ /^test=/){split($i,a,"="); test=a[2]}
          else if($i ~ /^series=/){split($i,a,"="); series=a[2]}
          else if($i ~ /^type=/){split($i,a,"="); type=a[2]}
          else if($i ~ /^size=/){split($i,a,"="); size=a[2]}
          else if($i ~ /^detail=/){sub(/^detail=/,"",$i); reason=$i}
        }
        gsub("\"","\\\"",reason);
        printf("{\"vm\":\"%s\",\"test\":\"%s\",\"series\":\"%s\",\"type\":\"%s\",\"size\":\"%s\",\"reason\":\"%s\"}\n", vm, test, series, type, size, reason)
      }' "$SKIP_LOG" | jq -s '.')
    fi

  # Temporary JSON of results for series/policies
    TMP_JSON="${ART_DIR}/.results_expanded.json"
    if [[ -f "$RES_LOG" ]]; then
      awk -F"|" '
        function kvgrab(k,   i,a){ for(i=1;i<=NF;i++){ if($i ~ "^"k"="){ split($i,a,"="); return a[2] } } return "" }
        /^(GOOD|BAD)\|/ {
          status=$1; vm=kvgrab("vm"); testn=kvgrab("test"); series=kvgrab("series");
          detail="";
          for(i=1;i<=NF;i++){ if($i ~ "^detail="){ sub("^detail=","",$i); detail=$i } }
          gsub(/"/, "\\\"", detail);
          printf("{\"status\":\"%s\",\"vm\":\"%s\",\"test\":\"%s\",\"series\":\"%s\",\"detail\":\"%s\"}\n", status, vm, testn, series, detail);
        }' "$RES_LOG" | jq -s '.' > "$TMP_JSON"
    else
      echo "[]" > "$TMP_JSON"
    fi

  # number of expected phases (default 3)
    EXPECTED_TESTS=3
    if [[ -f "tests-matrix.json" ]]; then
      EXPECTED_TESTS=$(jq -r '.tests[].name' "tests-matrix.json" 2>/dev/null | wc -l | tr -d ' ' || echo 3)
      [[ -z "$EXPECTED_TESTS" || "$EXPECTED_TESTS" -eq 0 ]] && EXPECTED_TESTS=3
    fi

    SERIES_STATS=$(jq --argjson n "$EXPECTED_TESTS" '
      group_by(.vm) as $byvm
      | $byvm
      | map({
          vm: .[0].vm,
          series: ( [.[].series] | map(select(type=="string" and length>0)) | first // "unknown"),
          good: [ .[] | select(.status=="GOOD") ] | length,
          bad:  [ .[] | select(.status=="BAD")  ] | length
        })
      | group_by(.series)
      | map({
          series: .[0].series,
          total_vms: length,
          failed_vms: ( map(select(.bad>0 or .good < $n)) | length )
        })' "$TMP_JSON")

    POLICY_FAILS=$(jq '
      [ .[] | select(.status=="BAD" and (.detail|test("\\[POLICY\\]"))) ]
      | map({
          vm, test,
          name: ( .detail | capture("name=(?<n>[^ ]+)") .n // "unknown"),
          message: ( .detail | capture("message=(?<m>.*)$") .m // "" )
        })
      | group_by(.name)
      | map({name: .[0].name, count: length, message: (.[0].message) })' "$TMP_JSON")

    jq -n \
      --arg run_id "${RUN_ID:-}" \
      --arg rg "$RG" \
      --arg loc "$LOCATION" \
      --arg series "$SERIES_FILTER" \
      --argjson jobs "$MAX_PARALLEL" \
      --argjson success_rate "$SUCCESS_RATE" \
      --argjson total_vms "$TOTAL_VMS" \
      --argjson skipped_combos "$TOTAL_SKIPS" \
      --argjson policy_failures "$BAD_CNT" \
      --argjson completion_rate "$COMPLETION_RATE" \
      --argjson good_cnt "$GOOD_CNT" \
      --argjson bad_cnt "$BAD_CNT" \
      --argjson done_cnt "$DONE_CNT" \
      --argjson good_details "$GOOD_DETAILS" \
      --argjson bad_details "$BAD_DETAILS" \
      --argjson skip_details "$SKIP_DETAILS" \
      --argjson series_stats "$SERIES_STATS" \
      --argjson policy_fails "$POLICY_FAILS" '
      {
        run_id: $run_id,
        resource_group: $rg,
        location: $loc,
        filters: { series: $series, max_parallel: $jobs },
        key_statistics: {
          success_rate:    $success_rate,
          total_vms:       $total_vms,
          critical_skips:  0,
          policy_failures: $policy_failures,
          completion_rate: $completion_rate,
          skipped_combos:  $skipped_combos
        },
        totals: { GOOD: $good_cnt, BAD: $bad_cnt, SKIP: $skipped_combos, DONE: $done_cnt },
        details: { good: $good_details, bad: $bad_details, skips: $skip_details },
        series_stats: $series_stats,
        policy_failures: $policy_fails
      }' > "$OUT_JSON"

  # if OUT_JSON is artifacts/summary.json and RUN_ID exists, write per-run and alias
      if [[ -n "${RUN_ID:-}" ]]; then
        local base_dir; base_dir="$(dirname "$OUT_JSON")"
        if [[ "$(basename "$OUT_JSON")" == "summary.json" ]]; then
          local OUT_JSON_RUN="${base_dir}/summary-${RUN_ID}.json"
      
          if command -v ln >/dev/null 2>&1; then
            ( cd "$base_dir" && ln -sf "summary-${RUN_ID}.json" "summary.json" )
          else
            cp -f "$OUT_JSON_RUN" "$base_dir/summary.json"
          fi
        fi
      fi
  fi
}
