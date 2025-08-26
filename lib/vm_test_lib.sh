# lib/vm_test_lib.sh
# Basic log wrappers (actual colors are in bootstrap.sh)
log()  { printf "[INFO] %s\n" "$*"; }
warn() { printf "[WARN] %s\n" "$*"; }
err()  { printf "[ERROR] %s\n" "$*" >&2; }

catalog_lookup() {
  local series="$1" type="$2"
  jq -r --arg s "$series" --arg t "$type" '
    .image_catalog[]? | select(.series==$s and .type==$t and .offer and .sku) | [.offer,.sku] | @tsv
  ' "$CONFIG" | head -n1
}

slugify() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' | cut -c1-63; }

label_for() {
  local type="$1" size="$2"
  case "$type" in
    amd64_*)
      case "$size" in
        Standard_E2ads_v6)  echo "nvme2-mlx" ;;
        Standard_D2alds_v6) echo "nvme1" ;;
        Standard_D2ls_v6)   echo "mana" ;;
        *)                  echo "amd64-other" ;;
      esac ;;
    arm64_*)
      case "$size" in
        Standard_E2pds_v6)  echo "nvme2-arm64" ;;
        Standard_D2pds_v6)  echo "nvme1-arm64" ;;
        Standard_D2plds_v6) echo "nvme1-arm64-2g" ;;
        Standard_D2ls_v6)   echo "mana-arm64" ;;
        *)                   echo "arm64-other" ;;
      esac ;;
    *) echo "unknown" ;;
  esac
}

arch_for() { [[ "$1" == arm64_* ]] && echo "arm" || echo "amd"; }

vm_exists() { az vm show -g "$rg" -n "$1" >/dev/null 2>&1; }

wait_ssh() {
  local ip="$1"
  for _ in $(seq 1 "${SSH_RETRIES:-40}"); do
    if ssh -i "$SSH_PRIV_DEFAULT" \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-6}" \
          -o ServerAliveInterval="${SERVER_ALIVE_INTERVAL:-10}" \
          -o ServerAliveCountMax="${SERVER_ALIVE_COUNTMAX:-6}" \
          -o ConnectionAttempts=1 \
          "${ADMIN_USER:-ubuntu}@${ip}" "echo ok" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${SSH_SLEEP:-5}"
  done
  return 1
}


wait_vm_running() {
  local name="$1"
  local retries="${VM_POWER_RETRIES:-60}"
  local sleep_s="${VM_POWER_SLEEP:-5}"
  log "[$name] Waiting for PowerState/running (retries=$retries, sleep=${sleep_s}s) ..."
  for _ in $(seq 1 "$retries"); do
    state="$(az vm get-instance-view -g "$rg" -n "$name" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code" -o tsv 2>/dev/null | tail -n1)"
    if [[ "$state" == "PowerState/running" ]]; then
      log "[$name] VM is running."
      return 0
    fi
    sleep "$sleep_s"
  done
  warn "[$name] VM did not reach PowerState/running in time (last state='${state:-unknown}')."
  return 1
}

restart_vm() {
  local name="$1"
  log "[$name] Restarting VM via Azure CLI..."
  if ! az vm restart -g "$rg" -n "$name" --no-wait >/dev/null 2>&1; then
    warn "[$name] 'az vm restart' failed (maybe deallocated). Trying 'az vm start'..."
    az vm start -g "$rg" -n "$name" >/dev/null
  fi
  sleep 10
}

run_remote() {
  local ip="$1" cmd="$2"
  local attempts="${SSH_CMD_RETRIES:-6}"
  local backoff_max="${SSH_MAX_BACKOFF:-20}"
  local try=1 rc

  # Escape single quotes inside the command to send
  local esc
  esc=$(printf "%s" "$cmd" | sed "s/'/'\"'\"'/g")

  while :; do
    set +e
    ssh -i "$SSH_PRIV_DEFAULT" \
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
       -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-6}" \
       -o ServerAliveInterval="${SERVER_ALIVE_INTERVAL:-10}" \
       -o ServerAliveCountMax="${SERVER_ALIVE_COUNTMAX:-6}" \
       -o ConnectionAttempts=1 \
       "${ADMIN_USER:-ubuntu}@${ip}" \
       "bash -lc 'set -eo pipefail; $esc'"
    rc=$?
    set -e

    if [ $rc -eq 0 ]; then
      return 0
    fi
  # Only retries on 255 (SSH loss). Other codes: return as is.
    if [ $rc -ne 255 ] || [ $try -ge $attempts ]; then
      return $rc
    fi

  # Exponential backoff with limit
    local sleep_s=$(( 1 << (try-1) ))
    if [ $sleep_s -gt $backoff_max ]; then sleep_s=$backoff_max; fi
    warn "[SSH] transient 255 running: ${cmd}; retry ${try}/${attempts} in ${sleep_s}s..."
    sleep "$sleep_s"
    try=$((try+1))
  done
}


append_skip() {
  printf "%s|series=%s|type=%s|size=%s|offer=%s|sku=%s|vm=%s|%s\n" \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$SKIP_LOG"
}

append_result() {
  local status="$1" series="$2" type="$3" size="$4" offer="$5" sku="$6" vm="$7" tname="$8" stdout_log="$9" detail="${10:-}"

  mkdir -p artifacts
  local results_log="artifacts/_results_summary.log"

  # Base line
  local line="$status|vm=$vm|test=$tname|series=$series|type=$type|size=$size|offer=$offer|sku=$sku"

  # Optional detail (policy failures, etc.)
  if [ -n "$detail" ]; then
  # Flatten & lightly escape so the line stays parseable:
  # - replace newlines with spaces
  # - encode pipes/semicolons which we use as delimiters
    detail="$(printf '%s' "$detail" | tr '\n' ' ' | sed 's/|/%7C/g; s/;/%3B/g')"
    line="$line|detail=$detail"
  fi

  echo "$line" >> "$results_log"
}


# ---- Metrics helpers & Policy evaluation ----
metrics_from_file() {
  local logfile="$1"
  [ -f "$logfile" ] || { echo "{}"; return 0; }
  awk -F'METRIC:' '/^METRIC:/{print $2}' "$logfile" | \
    awk -F'=' '{
      key=$1; sub(/^[ \t]+/,"",key); sub(/[ \t]+$/,"",key);
      $1=""; val=substr($0,2);
      gsub(/^[ \t]+|[ \t]+$/, "", val);
      printf("(%s)=(%s)\n", key, val);
    }' | \
    jq -Rn '
      reduce inputs as $line ({};
        ($line | capture("\\((?<k>[^)]*)\\)=\\((?<v>.*)\\)")) as $kv
        | . + {($kv.k): $kv.v}
      )'
}

collect_metrics_for_vm() {
  local vm="$1"
  local dir="artifacts/$vm"
  local merged='{}'
  [ -d "$dir" ] || { echo "$merged"; return 0; }
  local f
  while IFS= read -r -d '' f; do
    local m; m=$(metrics_from_file "$f")
    merged=$(jq -cn --argjson A "$merged" --argjson B "$m" '$A + $B')
  done < <(find "$dir" -mindepth 2 -maxdepth 2 -type f -name stdout.log -print0 2>/dev/null)
  echo "$merged"
}

# --- Data-driven evaluate_policies(): read rules from tests-matrix.json ---
evaluate_policies() {
  # Args: series type size test_name vm_name
  local series="$1" type="$2" size="$3" tname="$4" vm="$5"

  # jq: does JSON `has(<key>)` without quote hell
  _jq_has() { local key="$1" json="$2"; jq -r --arg k "$key" 'has($k)' <<<"$json"; }


  # Aggregated metrics for this VM (JSON object)
  local metrics; metrics=$(collect_metrics_for_vm "$vm")

  # Helpers
  _getm() { printf '%s' "$metrics" | jq -r --arg k "$1" '.[$k] // empty'; }
  _is_number() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
  _phase_of_tname() { [[ "$1" =~ ^phase([0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo 999; }
  local CUR_PHASE; CUR_PHASE=$(_phase_of_tname "$tname")

  _cmp() {
    local a="$1" op="$2" b="$3"
    if _is_number "$a" && _is_number "$b"; then
      case "$op" in
        eq)  awk -v A="$a" -v B="$b" 'BEGIN{exit !(A==B)}' ;;
        ne)  awk -v A="$a" -v B="$b" 'BEGIN{exit !(A!=B)}' ;;
        gt)  awk -v A="$a" -v B="$b" 'BEGIN{exit !(A>B)}' ;;
        lt)  awk -v A="$a" -v B="$b" 'BEGIN{exit !(A<B)}' ;;
        gte) awk -v A="$a" -v B="$b" 'BEGIN{exit !(A>=B)}' ;;
        lte) awk -v A="$a" -v B="$b" 'BEGIN{exit !(A<=B)}' ;;
        *) return 2 ;;
      esac
    else
      case "$op" in
        eq) [ "$a" = "$b" ] ;;
        ne) [ "$a" != "$b" ] ;;
        contains)   case "$a" in *"$b"*) return 0;; *) return 1;; esac ;;
        ncontains)  case "$a" in *"$b"*) return 1;; *) return 0;; esac ;;
        regex)      printf '%s' "$a" | grep -Eq "$b" ;;
        in)         IFS=, read -r -a arr <<< "$b"; for x in "${arr[@]}"; do [ "$a" = "$x" ] && return 0; done; return 1 ;;
        *) return 2 ;;
      esac
    fi
  }

  # mode: when | require ; strict: 0/1
  _eval_condition() {
    local cond="$1" mode="$2" strict="$3"
    local metric op value actual
    metric=$(jq -r '.metric // empty' <<<"$cond")
    op=$(jq -r '.op // "eq"'          <<<"$cond")
    value=$(jq -r '.value // empty'   <<<"$cond")
    actual=$(_getm "$metric")

  # Missing metric
    if [ -z "$actual" ]; then
      if [ "$mode" = "when" ]; then
  # When condition not met, skip rule
  return 1
      else
        if [ "$strict" = "1" ]; then
          # strict require on missing metric -> fail and record condition
          if [ "$mode" = "require" ]; then LAST_COND_DESC="metric=${metric} op=${op} expected=${value} actual=<missing>"; fi
          return 1
        else
          return 0  # require: defer unless non-strict
        fi
      fi
    fi
    _cmp "${actual:-}" "$op" "${value:-}"
  }

  _eval_group_all() {
    local arr="$1" mode="$2" strict="$3" ok=1
    while IFS= read -r cond; do
      if ! _eval_condition "$cond" "$mode" "$strict"; then ok=0; break; fi
    done < <(jq -c '.[]' <<<"$arr")
    [ $ok -eq 1 ]
  }
  _eval_group_any() {
    local arr="$1" mode="$2" strict="$3" ok=0
    while IFS= read -r cond; do
      if _eval_condition "$cond" "$mode" "$strict"; then ok=1; break; fi
    done < <(jq -c '.[]' <<<"$arr")
    [ $ok -eq 1 ]
  }

  _rule_applies_to_combo() {
    local json="$1"
    local type_glob size_match size_in series_match phase_at_least
    type_glob=$(jq -r '.match.type_glob // "*"' <<<"$json")
    series_match=$(jq -r '.match.series // "*"'   <<<"$json")
    size_match=$(jq -r '.match.size // ""'        <<<"$json")
    size_in=$(jq -r '.match.size_in // empty | @sh' <<<"$json")
    phase_at_least=$(jq -r '.phase_at_least // empty' <<<"$json")

  # minimum phase
    if [ -n "$phase_at_least" ] && [ "$CUR_PHASE" -lt "$phase_at_least" ]; then return 1; fi
  # series
    if [ "$series_match" != "*" ] && [ "$series_match" != "$series" ]; then return 1; fi
  # type glob
    case "$type" in $type_glob) : ;; *) return 1 ;; esac
  # exact size
    if [ -n "$size_match" ] && [ "$size_match" != "$size" ]; then return 1; fi
  # size_in
    if [ -n "$size_in" ]; then
      eval "arr=${size_in}"
      local found=0; for s in "${arr[@]}"; do [ "$s" = "$size" ] && found=1 && break; done
      [ $found -eq 1 ] || return 1
    fi
    return 0
  }

  _eval_require() {
    local req="$1" strict="$2" had=0 ok=1
    if [ "$(_jq_has all_of "$req")" = "true" ]; then
      had=1
      _eval_group_all "$(jq -c '.all_of' <<<"$req")" "require" "$strict" || ok=0
    fi
    if [ "$(_jq_has any_of "$req")" = "true" ]; then
      had=1
      _eval_group_any  "$(jq -c '.any_of'  <<<"$req")" "require" "$strict" || ok=0
    fi
    if [ $had -eq 0 ]; then _eval_condition "$req" "require" "$strict" || ok=0; fi
    [ $ok -eq 1 ]
  }

  local failures=()
  LAST_COND_DESC=""

  # 1) Global rules
  while IFS= read -r rule; do
    local name msg when require strict phase_at_least
    name=$(jq -r '.name // "global_rule"' <<<"$rule")
    msg=$(jq -r '.message // empty'       <<<"$rule")
    when=$(jq -c '.when // []'            <<<"$rule")
    require=$(jq -c '.require // {}'      <<<"$rule")
    strict=$(jq -r '.strict // false'     <<<"$rule")
    phase_at_least=$(jq -r '.phase_at_least // empty' <<<"$rule")

  # gating by phase (if exists)
    if [ -n "$phase_at_least" ] && [ "$CUR_PHASE" -lt "$phase_at_least" ]; then
      continue
    fi
  # WHEN (if exists and not met) -> skip rule
    if [ "$(jq -r 'length' <<<"$when")" != "0" ]; then
      _eval_group_all "$when" "when" "0" || continue
    fi
    if ! _eval_require "$require" "$strict"; then
      if [ -n "$LAST_COND_DESC" ]; then failures+=("[POLICY] name=${name} scope=GLOBAL cond=${LAST_COND_DESC} message=${msg}"); else failures+=("[POLICY] name=${name} scope=GLOBAL message=${msg}"); fi
    fi
  done < <(jq -c '.policies.global[]?' "$CONFIG")

  # 2) Rules by combination
  while IFS= read -r rule; do
    _rule_applies_to_combo "$rule" || continue
    local name msg require strict
    name=$(jq -r '.name // "combo_rule"' <<<"$rule")
    msg=$(jq -r '.message // empty'      <<<"$rule")
    require=$(jq -c '.require // {}'     <<<"$rule")
    strict=$(jq -r '.strict // false'    <<<"$rule")
    if ! _eval_require "$require" "$strict"; then
      if [ -n "$LAST_COND_DESC" ]; then failures+=("[POLICY] name=${name} scope=COMBO cond=${LAST_COND_DESC} message=${msg}"); else failures+=("[POLICY] name=${name} scope=COMBO message=${msg}"); fi
    fi
  done < <(jq -c '.policies.by_combo[]?' "$CONFIG")

  if [ ${#failures[@]} -gt 0 ]; then
    printf "%s\n" "${failures[@]}" | paste -sd '; ' -
    return 1
  fi
  return 0
}



build_worklist() {
  local series_filter="$1" _rg="$2" _loc="$3" _out_array_name="$4"
  local -n OUT="$4"
  for series in "${SERIES[@]}"; do
    [[ "$series_filter" != "all" && "$series" != "$series_filter" ]] && continue
    for type in "${TYPES[@]}"; do
      # Filter by --type (comma-separated)
      if [[ "${TYPE_FILTER:-all}" != "all" ]]; then
        IFS="," read -r -a _tf <<< "$TYPE_FILTER"
        _ok=0; for _t in "${_tf[@]}"; do [[ "$type" == "$_t" ]] && _ok=1 && break; done
        [[ $_ok -eq 1 ]] || continue
      fi
      

  # Filter by --arch (derived from type label if provided)
      _arch=$(arch_for "$type")
      if [[ "${ARCH_FILTER:-all}" != "all" && "$_arch" != "$ARCH_FILTER" ]]; then continue; fi

  # Lookup image offer/sku
      mapfile -t osline < <(catalog_lookup "$series" "$type" || true)
      if [ "${#osline[@]}" -eq 0 ]; then
        warn "SKIP (CATALOG): no entry for series='$series' type='$type'."
        append_skip "PRE:CATALOG" "$series" "$type" "*" "-" "-" "-" "No catalog entry"
        continue
      fi
      IFS=$'\t' read -r offer sku <<<"${osline[0]}"

  # Validate availability in region -> SKIP early if not
      offer_ok=$(az vm image list-offers --location "$_loc" --publisher "${PUBLISHER:-Canonical}" --query "[?name=='$offer'] | length(@)" -o tsv)
      if [ "$offer_ok" != "1" ]; then
        warn "SKIP: offer '$offer' not available in '$_loc'."
        append_skip "PRE:OFFER" "$series" "$type" "*" "$offer" "$sku" "-" "Offer not in region $_loc"
        continue
      fi
      sku_ok=$(az vm image list-skus --location "$_loc" --publisher "${PUBLISHER:-Canonical}" --offer "$offer" --query "[?name=='$sku'] | length(@)" -o tsv)
      if [ "$sku_ok" != "1" ]; then
        warn "SKIP: sku '$sku' not available under offer '$offer' in '$_loc'."
        append_skip "PRE:SKU" "$series" "$type" "*" "$offer" "$sku" "-" "SKU not in region $_loc"
        continue
      fi

      for size in "${SIZES[@]}"; do
  # Filter by --size (comma-separated)
        if [[ "${SIZE_FILTER:-all}" != "all" ]]; then
          IFS="," read -r -a _sf <<< "$SIZE_FILTER"
          _ok=0; for _s in "${_sf[@]}"; do [[ "$size" == "$_s" ]] && _ok=1 && break; done
          [[ $_ok -eq 1 ]] || continue
        fi

  # Arch-specific default filtering for known sizes
        if [[ "$_arch" == arm ]]; then
          case "$size" in
            Standard_E2pds_v6|Standard_D2pds_v6|Standard_D2plds_v6) : ;;
            *) append_skip "PRE:SIZE_FILTER" "$series" "$type" "$size" "$offer" "$sku" "-" "ARM64 only E2pds_v6/D2pds_v6/D2plds_v6"; continue ;;
          esac
        else
          case "$size" in
            Standard_E2ads_v6|Standard_D2alds_v6|Standard_D2ls_v6) : ;;
            *) append_skip "PRE:SIZE_FILTER" "$series" "$type" "$size" "$offer" "$sku" "-" "AMD64 only E2ads_v6/D2alds_v6/D2ls_v6"; continue ;;
          esac
        fi

        vm_label="$(label_for "$type" "$size")"
        name_raw="${vm_name_pattern//\{series\}/$series}"
        name_raw="${name_raw//\{type\}/$type}"
        name_raw="${name_raw//\{size\}/$vm_label}"
        vm_name="$(slugify "$name_raw")"

        OUT+=("${series}|${type}|${size}|${offer}|${sku}|${vm_name}")
      done
    done
  done
}

run_combo() {
  local series="$1" type="$2" size="$3" offer="$4" sku="$5" vm_name="$6"

  log "[$vm_name] Starting -> series=$series type=$type size=$size offer=$offer sku=$sku"
  log "[$vm_name] Label: $(label_for "$type" "$size") | Arch: $(arch_for "$type")"
  local artifacts_dir="artifacts/${vm_name}"
  mkdir -p "$artifacts_dir"

  if vm_exists "$vm_name"; then
    log "[$vm_name] VM already exists."
  else
    local create_log="${artifacts_dir}/_create_output.log"
    local arch; arch="$(arch_for "$type")"
    local label; label="$(label_for "$type" "$size")"
    local image="${PUBLISHER:-Canonical}:$offer:$sku:${VERSION:-latest}"
    log "[$vm_name] Creating VM with urn image='$image' ..."

    if ! az vm create \
         --resource-group "$rg" \
         --name "$vm_name" \
         --image "$image" \
         --size "$size" \
         --admin-username "${ADMIN_USER:-ubuntu}" \
         --ssh-key-values "$SSH_PUB_DEFAULT" \
         --tags "arch=$arch" "driver=$label" "series=$series" "type=$type" \
                "size=$size" "offer=$offer" "sku=$sku" "label=$label" \
                "created=$(date -u +%Y%m%dT%H%M%SZ)" \
         >"$create_log" 2>&1; then
      err "[$vm_name] VM creation failed. Logged at $create_log"
      append_skip "RUN:CREATE" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "az vm create failed (see $create_log)"
      return 72
    fi
    log "[$vm_name] VM created."
    echo "$vm_name" >> "$CREATED_VMS_FILE"
  fi

  local PUBLIC_IP
  PUBLIC_IP=$(az vm show -d -g "$rg" -n "$vm_name" --query publicIps -o tsv)
  if [ -z "$PUBLIC_IP" ]; then
    err "[$vm_name] Failed to obtain public IP"
    append_skip "RUN:IP" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "No public IP"
    return 70
  fi
  log "[$vm_name] IP: $PUBLIC_IP"

  if ! wait_ssh "$PUBLIC_IP"; then
    err "[$vm_name] SSH not reachable — skipping tests."
    append_skip "RUN:SSH" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "SSH not reachable"
    return 71
  fi

  local tests_count_local
  local tname
  tests_count_local=$(jq '.tests | length' "$CONFIG")
  for idx in $(seq 0 $((tests_count_local-1))); do
    tname=$(jq -r ".tests[$idx].name" "$CONFIG")
    local tdir="artifacts/${vm_name}/${tname}"
    mkdir -p "$tdir"
    local stdout_log="${tdir}/stdout.log"; : > "$stdout_log"
  # Accumulated failure detail per test (CMDFAIL / SSH_LOST / POLICY ...)
    local bad_detail=""

    log "[$vm_name] Running test '${tname}' ..."
    mapfile -t cmds < <(jq -r ".tests[$idx].commands[]?" "$CONFIG")
    test_status="GOOD"
    
    cmds_len=${#cmds[@]}
    
    for cidx in "${!cmds[@]}"; do
      line="${cmds[$cidx]}"
    
  # --- Selective SKIP: last 3 commands of phase3 for minimal/fde types ---
      if [[ "$tname" == "phase3-postchecks" ]] \
         && [[ "$type" == *minimal* || "$type" == *fde* ]] \
         && (( cmds_len >= 3 && cidx >= cmds_len - 3 )); then
        echo "[SKIP] phase3: saltando cmd ${cidx}/${cmds_len} para type='$type'" | tee -a "$stdout_log"
        append_skip "RUN:PHASE3_CMD_SKIP" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" \
                    "Skipped last 3 phase3 commands for minimal/fde"
        continue
      fi
  # ---------------------------------------------------------------------------
    
      if [[ "$line" == "#REBOOT#" ]]; then
        echo -e "\n${C_INFO}[TEST]${C_RESET} Requesting VM reboot ..." | tee -a "$stdout_log"
        restart_vm "$vm_name"
        if ! wait_ssh "$PUBLIC_IP"; then
          err "[$vm_name] SSH did not recover after reboot"
          append_skip "RUN:REBOOT_SSH" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "SSH did not recover after reboot"
          test_status="BAD"
          break
        fi
        continue
      fi
    
      echo -e "\n${C_CMD}[COMMAND]${C_RESET} $line" | tee -a "$stdout_log"
      set +e
      run_remote "$PUBLIC_IP" "$line" 2>&1 | tee -a "$stdout_log"
      rc=${PIPESTATUS[0]}
      set -e
      if [ $rc -ne 0 ]; then
        echo "[ERROR] Command failed with exit code $rc" | tee -a "$stdout_log"
        if [ $rc -eq 255 ] && [ "${SSH_RETRY_ON_LOSS:-1}" = "1" ] && [ "${_retried:-0}" -eq 0 ]; then
          log "[$vm_name] SSH 255 detected, retrying command once after 10s…"
          sleep 10
          _retried=1
      # retry the same command
          set +e
          run_remote "$PUBLIC_IP" "$line" 2>&1 | tee -a "$stdout_log"
          rc=${PIPESTATUS[0]}
          set -e
        fi
        if [ $rc -eq 255 ]; then
          append_skip "RUN:SSH_LOST" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" \
                      "SSH connection lost (exit 255) while running: ${line}"
          bad_detail="${bad_detail:+$bad_detail; }[CRITICAL] SSH_LOST exit=255 cmd=$(printf '%s' "$line" | tr '\n' ' ' | cut -c1-160)"
        else
          bad_detail="${bad_detail:+$bad_detail; }[CMDFAIL] exit=$rc cmd=$(printf '%s' "$line" | tr '\n' ' ' | cut -c1-200)"
        fi
        test_status="BAD"
        break  # abort current phase on first failure
      fi
    done

  # Evaluate policies ONLY if the test commands went well.
  # If there was CMDFAIL/SSH_LOST, do not mix with policies.
    local pol_reason=""
    if [ "$test_status" = "GOOD" ]; then
      if ! pol_reason="$(evaluate_policies "$series" "$type" "$size" "$tname" "$vm_name" 2>&1)"; then
        test_status="BAD"
  # accumulate policy detail
        bad_detail="${bad_detail:+$bad_detail; }${pol_reason}"
      fi
    fi

  # Pretty-print each policy line to the phase log
    if [ -n "$pol_reason" ]; then
      echo "$pol_reason" | tr ';' '\n' | sed 's/^ *//' | while read -r pl; do
        log "[$vm_name] $pl"
      done
    fi

  # Marks phase as completed (policies gating)
    case "$tname" in
      phase1*) echo "METRIC:phase1_done=1" | tee -a "$stdout_log" ;;
      phase2*) echo "METRIC:phase2_done=1" | tee -a "$stdout_log" ;;
      phase3*) echo "METRIC:phase3_done=1" | tee -a "$stdout_log" ;;
    esac

    append_result "$test_status" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "$tname" "$stdout_log" "${bad_detail:-}"
    log "[$vm_name] Test '${tname}' -> ${test_status}"
    if [ "$test_status" = "BAD" ]; then
      remaining=$((tests_count_local - idx - 1))
      warn "[$vm_name] Phase '${tname}' failed — aborting remaining ${remaining} phase(s) for this VM."
      if [ "$remaining" -gt 0 ]; then
        append_skip "RUN:ABORT_REST" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "Aborted remaining ${remaining} phase(s) after failure in '${tname}'"
      fi
      return 0
    fi
  done

  log "[$vm_name] Completed."
}

print_final_summary() {
  local results_log="$1" skip_log="$2"

  local GOOD_CNT BAD_CNT SKIP_CNT
  GOOD_CNT=$(awk -F'|' '/^GOOD\|/{c++} END{print c+0}' "$results_log" 2>/dev/null)
  BAD_CNT=$(awk -F'|'  '/^BAD\|/{c++}  END{print c+0}' "$results_log"  2>/dev/null)
  SKIP_CNT=$(awk 'END{print NR+0}' "$skip_log" 2>/dev/null)

  printf "%b==== FINAL SUMMARY (GOOD / BAD / SKIP) ====%b\n" "${C_INFO}" "${C_RESET}"
  printf "%bGOOD: %s%b\n" "${C_GOOD:-$C_INFO}" "${GOOD_CNT}" "${C_RESET}"
  printf "%bBAD:  %s%b\n" "${C_ERR}" "${BAD_CNT}" "${C_RESET}"
  printf "%bSKIP: %s%b\n" "${C_WARN}" "${SKIP_CNT}" "${C_RESET}"

  # Desglose de BAD por tipo
  local BAD_POLICY_CNT BAD_CMD_CNT
  BAD_POLICY_CNT=$(awk -F'|' '/^BAD\|/ && /\[POLICY\]/ {c++} END{print c+0}' "$results_log" 2>/dev/null)
  BAD_CMD_CNT=$(awk -F'|' '/^BAD\|/ && !/\[POLICY\]/ {c++} END{print c+0}' "$results_log" 2>/dev/null)
  if [ "$BAD_CNT" -gt 0 ]; then
    printf "  • Failures breakdown → Policy: %d   Cmd/Runtime: %d\n" "$BAD_POLICY_CNT" "$BAD_CMD_CNT"
  fi

  count_skip_code() { awk -F'|' -v code="$1" '$1==code{n++} END{print n+0}' "$skip_log" 2>/dev/null; }
  CRIT_CREATE=$(count_skip_code 'RUN:CREATE')
  CRIT_IP=$(count_skip_code 'RUN:IP')
  CRIT_SSH=$(count_skip_code 'RUN:SSH')
  CRIT_REBOOT=$(count_skip_code 'RUN:REBOOT_SSH')
  CRIT_POWER=$(count_skip_code 'RUN:REBOOT_POWER')
  CRIT_CREATE_POWER=$(count_skip_code 'RUN:CREATE_POWER')
  CRIT_ABORT=$(count_skip_code 'RUN:ABORT_REST')
  CRIT_SSH_LOST=$(count_skip_code 'RUN:SSH_LOST')
  CRIT_TOTAL=$(( CRIT_CREATE + CRIT_IP + CRIT_SSH + CRIT_REBOOT + CRIT_POWER + CRIT_CREATE_POWER + CRIT_ABORT +  CRIT_SSH_LOST))

  printf "%b-- CRITICAL SKIPS --%b\n" "${C_WARN}" "${C_RESET}"
  printf "RUN:CREATE     = %d\n" "$CRIT_CREATE"
  printf "RUN:IP         = %d\n" "$CRIT_IP"
  printf "RUN:SSH        = %d\n" "$CRIT_SSH"
  printf "RUN:SSH_LOST = %d\n" "$CRIT_SSH_LOST"
  printf "RUN:REBOOT_SSH = %d\n" "$CRIT_REBOOT"
  printf "RUN:REBOOT_POWER = %d\n" "$CRIT_POWER"
  printf "RUN:CREATE_POWER = %d\n" "$CRIT_CREATE_POWER"
  if [ "$CRIT_TOTAL" -gt 0 ]; then
    printf "%b-- Critical SKIP details --%b\n" "${C_WARN}" "${C_RESET}"
    grep -E '^(RUN:CREATE|RUN:IP|RUN:SSH|RUN:REBOOT_SSH)\|' "$skip_log" || true
  fi

  if [ "$GOOD_CNT" -gt 0 ]; then
    printf "%b-- GOOD details --%b\n" "${C_GOOD:-$C_INFO}" "${C_RESET}"
    grep '^GOOD|' "$results_log"
  fi
  if [ "$BAD_CNT" -gt 0 ]; then
    printf "%b-- BAD details --%b\n" "${C_ERR}" "${C_RESET}"
    grep '^BAD|' "$results_log"
    # -- POLICY FAILURES details --  
    POL_ANY=$(grep '\[POLICY\]' "$results_log" 2>/dev/null || true)
    if [ -n "$POL_ANY" ]; then
      printf "%b-- POLICY FAILURES details --%b\n" "${C_ERR}" "${C_RESET}"
      awk -F'|' '
        function urldecode(s) { gsub(/%7C/,"|",s); gsub(/%3B/,";",s); return s }
        {
          vm=""; test=""; detail="";
          for(i=1;i<=NF;i++){
            if ($i ~ /^vm=/) vm=substr($i,4);
            else if ($i ~ /^test=/) test=substr($i,6);
            else if ($i ~ /^detail=/) { detail=substr($i,8); detail=urldecode(detail); }
          }
          if (detail=="") next;
          n=split(detail, arr, /;[ ]*/);
          for (j=1;j<=n;j++){
            p=arr[j];
            if (p ~ /\[POLICY\]/) {
              name=""; scope=""; msg="";
              if (match(p, /name=([^ ]+)/, m)) name=m[1];
              if (match(p, /scope=([^ ]+)/, m)) scope=m[1];
              if (match(p, /message=(.*)$/, m)) msg=m[1];
              printf("- VM %s • test %s • policy \"%s\" (scope: %s) -> %s\n", vm, test, name, scope, msg);
            }
          }
        }
      ' "$results_log"
    fi
    # -- Command/Runtime failures (sin [POLICY]) --
    if [ "$BAD_CMD_CNT" -gt 0 ]; then
      printf "%b-- CMD/Runtime FAILURES details --%b\n" "${C_ERR}" "${C_RESET}"
      awk -F'|' '
        function urldecode(s){ gsub(/%7C/,"|",s); gsub(/%3B/,";",s); return s }
        /^BAD\|/ && $0 !~ /\[POLICY\]/ {
          vm=""; test=""; detail="";
          for(i=1;i<=NF;i++){
            if($i ~ /^vm=/) vm=substr($i,4);
            else if($i ~ /^test=/) test=substr($i,6);
            else if($i ~ /^detail=/){ detail=urldecode(substr($i,8)); }
          }
          if(detail==""){ printf("- VM %s • test %s\n", vm, test); next }
          # si hay [CMDFAIL], muéstralo resumido
          if(match(detail, /\[CMDFAIL\][^;]*/)){
            frag=substr(detail, RSTART, RLENGTH);
            printf("- VM %s • test %s • %s\n", vm, test, frag);
          } else {
            printf("- VM %s • test %s • %s\n", vm, test, detail);
          }
        }' "$results_log"
    fi
  fi
  if [ "$SKIP_CNT" -gt 0 ]; then
    printf "%b-- SKIP details (all) --%b\n" "${C_WARN}" "${C_RESET}"
    cat "$skip_log"
  fi
}

# ----------------------------------------------------------------------
# print_final_summary_ext(): resumen extendido (requiere jq)
#  - Nº de VMs con tests (excluye SKIPs)
#  - Nº de VMs con todas las fases OK (GOOD-only y >= nº fases)
#  - Series completadas
#  - Por serie: failed/total
#  - Detalle de políticas falladas
# Lee artifacts/_results_summary.log y tests-matrix.json
# ----------------------------------------------------------------------
print_final_summary_ext() {
  local ART="${1:-artifacts}"
  local MATRIX="${2:-tests-matrix.json}"
  local RES="${ART}/_results_summary.log"

  if ! command -v jq >/dev/null 2>&1; then
    echo "[WARN] jq no está disponible; no puedo imprimir el resumen extendido." >&2
    return 0
  fi
  [[ -f "$RES" ]] || { echo "[INFO] No hay resultados en $RES"; return 0; }

  local EXPECTED_TESTS
  if [[ -f "$MATRIX" ]]; then
    EXPECTED_TESTS=$(jq -r '.tests[].name' "$MATRIX" 2>/dev/null | wc -l | tr -d ' ')
  fi
  [[ -z "${EXPECTED_TESTS:-}" || "$EXPECTED_TESTS" -eq 0 ]] && EXPECTED_TESTS=3

  # JSON intermedio a partir de _results_summary.log
  local TMP_JSON="$ART/.results_expanded.json"
  awk -F'|' '
    function kvgrab(k,   i,a){
      for(i=1;i<=NF;i++){
        if($i ~ "^"k"="){ split($i,a,"="); return a[2]; }
      }
      return ""
    }
    /^(GOOD|BAD)\|/ {
      status=$1;
      vm=kvgrab("vm");
      testn=kvgrab("test");
      series=kvgrab("series");
      size=kvgrab("size");                 # <-- NUEVO
      detail="";
      for(i=1;i<=NF;i++){ if($i ~ "^detail="){ sub("^detail=","",$i); detail=$i } }
      gsub(/"/, "\\\"", detail);
      printf("{\"status\":\"%s\",\"vm\":\"%s\",\"test\":\"%s\",\"series\":\"%s\",\"size\":\"%s\",\"detail\":\"%s\"}\n",
             status, vm, testn, series, size, detail);
    }' "$RES" | jq -s '.' > "$TMP_JSON"    # ojo: jq -s '.'

  local TOTAL_VMS VMS_ALL_OK SERIES_TABLE SERIES_COMPLETED POLICY_TABLE
  TOTAL_VMS=$(jq 'map(.vm)|unique|length' "$TMP_JSON")
  VMS_ALL_OK=$(jq --argjson n "$EXPECTED_TESTS" '
    group_by(.vm) | map({
      vm: .[0].vm,
      good: [ .[] | select(.status=="GOOD") ] | length,
      bad:  [ .[] | select(.status=="BAD")  ] | length
    }) | map(select(.bad==0 and .good>= $n)) | length' "$TMP_JSON")
  SERIES_TABLE=$(jq --argjson n "$EXPECTED_TESTS" '
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
  SERIES_COMPLETED=$(echo "$SERIES_TABLE" | jq -r '[ .[] | select(.failed_vms==0 and .total_vms>0) | .series ] | join(", ")')
  [[ -z "$SERIES_COMPLETED" ]] && SERIES_COMPLETED="(none)"
  POLICY_TABLE=$(jq -r '
    [ .[] | select(.status=="BAD" and (.detail|test("\\[POLICY\\]"))) ]
    | map({
        vm,
        size: (.size // "unknown"),
        test,
        name: ( .detail | capture("name=(?<n>[^ ]+)") .n // "unknown"),
        message: ( .detail | capture("message=(?<m>.*)$") .m // "" )
      })
    | group_by(.name)
    | map({
        name: .[0].name,
        message: (.[0].message),
        count: length,
        failures: ( map({vm, size}) | unique | sort_by(.vm) )
      })
  ' "$TMP_JSON")

  echo "==== FINAL SUMMARY (EXTENDED) ===="
  echo "VMs with tests:         ${TOTAL_VMS}"
  echo "VMs all phases OK:      ${VMS_ALL_OK} / ${TOTAL_VMS}"
  echo "Completed series:       ${SERIES_COMPLETED}"
  echo "-- Fails by series (failed/total) --"
  echo "$SERIES_TABLE" | jq -r '.[] | "  \(.series): \(.failed_vms)/\(.total_vms)"'
  echo "-- Failed policies --"
  if [[ -n "$POLICY_TABLE" && "$POLICY_TABLE" != "[]" ]]; then
    # Cabecera por política
    echo "$POLICY_TABLE" | jq -r '.[] | "  [\(.count)x] \(.name) - \(.message)"'
    # Lista de VMs (con size) bajo cada política
    echo "$POLICY_TABLE" | jq -r '
      .[] | ( .failures | map("       - \(.vm) (size=\(.size))") | join("\n") )
    '
  else
    echo "  (none)"
  fi
  echo "=================================="
}

