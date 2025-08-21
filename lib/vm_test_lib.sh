#!/bin/bash
# lib/vm_test_lib.sh - Versión con sintaxis bash corregida
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

arch_for() { 
  [[ "$1" == arm64_* ]] && echo "arm" || echo "amd"
}

vm_exists() { 
  az vm show -g "$rg" -n "$1" >/dev/null 2>&1
}

# ===== Sistema de timeouts adaptativos =====
configure_adaptive_timeouts() {
  local location="$1" vm_size="$2"
  
  # Timeouts base por región
  case "$location" in
    eastus|westus2|centralus)
      SSH_BASE_TIMEOUT=60
      VM_POWER_BASE_TIMEOUT=180
      ;;
    northeurope|westeurope)
      SSH_BASE_TIMEOUT=90
      VM_POWER_BASE_TIMEOUT=240
      ;;
    *)
      SSH_BASE_TIMEOUT=120
      VM_POWER_BASE_TIMEOUT=300
      ;;
  esac
  
  # Multiplicadores por tamaño de VM
  local size_multiplier=1.0
  case "$vm_size" in
    Standard_E*) size_multiplier=1.2 ;;
    Standard_D*) size_multiplier=1.0 ;;
    *) size_multiplier=1.5 ;;
  esac
  
  # Aplicar multiplicadores
  SSH_RETRIES=$(awk "BEGIN {printf \"%.0f\", $SSH_BASE_TIMEOUT * $size_multiplier / 5}")
  VM_POWER_RETRIES=$(awk "BEGIN {printf \"%.0f\", $VM_POWER_BASE_TIMEOUT * $size_multiplier / 5}")
  SSH_SLEEP=5
  VM_POWER_SLEEP=5
  
  log "Adaptive timeouts for $location/$vm_size: SSH_RETRIES=$SSH_RETRIES, VM_POWER_RETRIES=$VM_POWER_RETRIES"
}

detect_network_issues() {
  local location="$1"
  local failures=0
  
  for endpoint in "management.azure.com" "${location}.cloudapp.azure.com"; do
    if ! timeout 10 ping -c 3 -W 5 "$endpoint" >/dev/null 2>&1; then
      failures=$((failures + 1))
      warn "Network connectivity issue detected for $endpoint"
    fi
  done
  
  if [ $failures -gt 0 ]; then
    warn "Network issues detected. Increasing timeouts by 50%"
    SSH_RETRIES=$((SSH_RETRIES * 3 / 2))
    VM_POWER_RETRIES=$((VM_POWER_RETRIES * 3 / 2))
  fi
}

# ===== SSH robusto con retry inteligente =====
run_remote_with_retry() {
  local ip="$1" cmd="$2" max_retries="${3:-2}" retry_delay="${4:-10}"
  local attempt=1
  
  while [ $attempt -le $max_retries ]; do
    log "[$ip] ATTEMPT $attempt/$max_retries: $cmd"
    
    set +e
    timeout 300 ssh -i "$SSH_PRIV_DEFAULT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}" \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        "${ADMIN_USER:-ubuntu}@${ip}" \
        "set -eo pipefail; ${cmd}" 2>&1
    local rc=$?
    set -e
    
    case $rc in
      0) return 0 ;;
      124)
        if [ $attempt -lt $max_retries ]; then
          warn "Command timed out. Retrying in ${retry_delay}s..."
          sleep $retry_delay
        else
          err "Command timed out after $max_retries attempts"
          return 124
        fi
        ;;
      255)
        if [ $attempt -lt $max_retries ]; then
          warn "SSH connection lost (exit 255). Retrying in ${retry_delay}s..."
          sleep $retry_delay
        else
          err "SSH connection failed after $max_retries attempts"
          return 255
        fi
        ;;
      *) 
        err "Command failed with exit code $rc"
        return $rc
        ;;
    esac
    
    attempt=$((attempt + 1))
  done
}

run_remote() {
  local ip="$1" cmd="$2"
  run_remote_with_retry "$ip" "$cmd" 2 10
}

wait_ssh() {
  local ip="$1"
  log "[$ip] Testing SSH connectivity (retries=$SSH_RETRIES, sleep=${SSH_SLEEP}s)..."
  
  for i in $(seq 1 "${SSH_RETRIES:-40}"); do
    if timeout 15 ssh -i "$SSH_PRIV_DEFAULT" \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o LogLevel=ERROR \
          -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-6}" \
          "${ADMIN_USER:-ubuntu}@${ip}" "echo ok" >/dev/null 2>&1; then
      log "[$ip] SSH connectivity established after $i attempts"
      return 0
    fi
    [ $((i % 10)) -eq 0 ] && log "[$ip] SSH attempt $i/$SSH_RETRIES..."
    sleep "${SSH_SLEEP:-5}"
  done
  
  err "[$ip] SSH not reachable after $SSH_RETRIES attempts"
  return 1
}

wait_vm_running() {
  local name="$1"
  local retries="${VM_POWER_RETRIES:-60}"
  local sleep_s="${VM_POWER_SLEEP:-5}"
  
  log "[$name] Waiting for PowerState/running (retries=$retries, sleep=${sleep_s}s)..."
  
  for i in $(seq 1 "$retries"); do
    local state
    state="$(az vm get-instance-view -g "$rg" -n "$name" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code" -o tsv 2>/dev/null | tail -n1)"
    
    case "$state" in
      "PowerState/running")
        log "[$name] VM is running after $i attempts"
        return 0
        ;;
      "PowerState/stopped"|"PowerState/deallocated")
        warn "[$name] VM is in state '$state', attempting start..."
        az vm start -g "$rg" -n "$name" --no-wait >/dev/null 2>&1 || true
        ;;
      *)
        [ $((i % 12)) -eq 0 ] && log "[$name] Current state: '${state:-unknown}' (attempt $i/$retries)"
        ;;
    esac
    
    sleep "$sleep_s"
  done
  
  warn "[$name] VM did not reach PowerState/running in time (last state='${state:-unknown}')"
  return 1
}

restart_vm() {
  local name="$1"
  log "[$name] Restarting VM via Azure CLI..."
  
  if ! az vm restart -g "$rg" -n "$name" --no-wait >/dev/null 2>&1; then
    warn "[$name] 'az vm restart' failed (maybe deallocated). Trying 'az vm start'..."
    az vm start -g "$rg" -n "$name" --no-wait >/dev/null 2>&1 || true
  fi
  
  sleep 15
  wait_vm_running "$name"
}

append_skip() {
  printf "%s|series=%s|type=%s|size=%s|offer=%s|sku=%s|vm=%s|%s\n" \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$SKIP_LOG"
}

append_result() {
  local status="$1" series="$2" type="$3" size="$4" offer="$5" sku="$6" vm="$7" tname="$8" stdout_log="$9" detail="${10:-}"

  mkdir -p artifacts
  local results_log="artifacts/_results_summary.log"
  local line="$status|vm=$vm|test=$tname|series=$series|type=$type|size=$size|offer=$offer|sku=$sku"

  if [ -n "$detail" ]; then
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

# --- Data-driven evaluate_policies ---
evaluate_policies() {
  local series="$1" type="$2" size="$3" tname="$4" vm="$5"
  local metrics; metrics=$(collect_metrics_for_vm "$vm")

  # Helper functions
  _jq_has() { 
    local key="$1" json="$2"
    jq -r --arg k "$key" 'has($k)' <<<"$json"
  }
  
  _getm() { 
    printf '%s' "$metrics" | jq -r --arg k "$1" '.[$k] // empty'
  }
  
  _is_number() { 
    [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
  }
  
  _phase_of_tname() { 
    [[ "$1" =~ ^phase([0-9]+) ]] && echo "${BASH_REMATCH[1]}" || echo 999
  }
  
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
        in)         
          IFS=, read -r -a arr <<< "$b"
          for x in "${arr[@]}"; do 
            [ "$a" = "$x" ] && return 0
          done
          return 1
          ;;
        *) return 2 ;;
      esac
    fi
  }

  _eval_condition() {
    local cond="$1" mode="$2" strict="$3"
    local metric op value actual
    metric=$(jq -r '.metric // empty' <<<"$cond")
    op=$(jq -r '.op // "eq"'          <<<"$cond")
    value=$(jq -r '.value // empty'   <<<"$cond")
    actual=$(_getm "$metric")

    if [ -z "$actual" ]; then
      if [ "$mode" = "when" ]; then
        return 1
      else
        [ "$strict" = "1" ] && return 1 || return 0
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

  # FIXED: _rule_applies_to_combo function without eval usage
  _rule_applies_to_combo() {
    local json="$1"
    local type_glob size_match series_match phase_at_least
    type_glob=$(jq -r '.match.type_glob // "*"' <<<"$json")
    series_match=$(jq -r '.match.series // "*"'   <<<"$json")
    size_match=$(jq -r '.match.size // ""'        <<<"$json")
    phase_at_least=$(jq -r '.phase_at_least // empty' <<<"$json")

    # Check phase
    if [ -n "$phase_at_least" ] && [ "$CUR_PHASE" -lt "$phase_at_least" ]; then 
      return 1
    fi
    
    # Check series
    if [ "$series_match" != "*" ] && [ "$series_match" != "$series" ]; then 
      return 1
    fi
    
    # Check type glob
    case "$type" in 
      $type_glob) : ;; 
      *) return 1 ;; 
    esac
    
    # Check size exact match
    if [ -n "$size_match" ] && [ "$size_match" != "$size" ]; then 
      return 1
    fi
    
    # FIXED: Check size_in array without dangerous eval
    local has_size_in
    has_size_in=$(jq -r '.match | has("size_in")' <<<"$json" 2>/dev/null || echo "false")
    if [ "$has_size_in" = "true" ]; then
      local size_found=false
      while IFS= read -r size_item; do
        [ -z "$size_item" ] && continue
        if [ "$size_item" = "$size" ]; then
          size_found=true
          break
        fi
      done < <(jq -r '.match.size_in[]?' <<<"$json" 2>/dev/null || true)
      
      if [ "$size_found" = "false" ]; then
        return 1
      fi
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
    if [ $had -eq 0 ]; then 
      _eval_condition "$req" "require" "$strict" || ok=0
    fi
    [ $ok -eq 1 ]
  }

  local failures=()

  # Process global policies
  while IFS= read -r rule; do
    local name msg when require strict phase_at_least
    name=$(jq -r '.name // "global_rule"' <<<"$rule")
    msg=$(jq -r '.message // empty'       <<<"$rule")
    when=$(jq -c '.when // []'            <<<"$rule")
    require=$(jq -c '.require // {}'      <<<"$rule")
    strict=$(jq -r '.strict // false'     <<<"$rule")
    phase_at_least=$(jq -r '.phase_at_least // empty' <<<"$rule")

    if [ -n "$phase_at_least" ] && [ "$CUR_PHASE" -lt "$phase_at_least" ]; then
      continue
    fi
    
    if [ "$(jq -r 'length' <<<"$when")" != "0" ]; then
      _eval_group_all "$when" "when" "0" || continue
    fi
    
    _eval_require "$require" "$strict" || failures+=("[POLICY] name=${name} scope=GLOBAL message=${msg}")
  done < <(jq -c '.policies.global[]?' "$CONFIG")

  # Process combo policies  
  while IFS= read -r rule; do
    _rule_applies_to_combo "$rule" || continue
    local name msg require strict
    name=$(jq -r '.name // "combo_rule"' <<<"$rule")
    msg=$(jq -r '.message // empty'      <<<"$rule")
    require=$(jq -c '.require // {}'     <<<"$rule")
    strict=$(jq -r '.strict // false'    <<<"$rule")
    _eval_require "$require" "$strict" || failures+=("[POLICY] name=${name} scope=COMBO message=${msg}")
  done < <(jq -c '.policies.by_combo[]?' "$CONFIG")

  if [ ${#failures[@]} -gt 0 ]; then
    printf "%s\n" "${failures[@]}" | paste -sd '; ' -
    return 1
  fi
  return 0
}

validate_combination() {
  local series="$1" type="$2" size="$3"
  
  local catalog_entry
  catalog_entry=$(jq -r --arg s "$series" --arg t "$type" '
    .image_catalog[] | select(.series==$s and .type==$t) | .offer + ":" + .sku
  ' "$CONFIG")
  
  if [ -z "$catalog_entry" ]; then
    return 1
  fi
  
  case "$type" in
    arm64_*)
      case "$size" in
        Standard_E2ads_v6|Standard_D2alds_v6) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    amd64_*)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

build_worklist() {
  local series_filter="$1" _rg="$2" _loc="$3" _out_array_name="$4"
  local -n OUT="$4"

  for series in "${SERIES[@]}"; do
    [[ "$series_filter" != "all" && "$series" != "$series_filter" ]] && continue
    for type in "${TYPES[@]}"; do
      if [[ "${TYPE_FILTER:-all}" != "all" ]]; then
        IFS="," read -r -a _tf <<< "$TYPE_FILTER"
        _ok=0; for _t in "${_tf[@]}"; do [[ "$type" == "$_t" ]] && _ok=1 && break; done
        [[ $_ok -eq 1 ]] || continue
      fi

      _arch=$(arch_for "$type")
      if [[ "${ARCH_FILTER:-all}" != "all" && "$_arch" != "$ARCH_FILTER" ]]; then continue; fi

      mapfile -t osline < <(catalog_lookup "$series" "$type" || true)
      if [ "${#osline[@]}" -eq 0 ]; then
        warn "SKIP (CATALOG): no entry for series='$series' type='$type'."
        append_skip "PRE:CATALOG" "$series" "$type" "*" "-" "-" "-" "No catalog entry"
        continue
      fi
      IFS=$'\t' read -r offer sku <<<"${osline[0]}"

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
        if [[ "${SIZE_FILTER:-all}" != "all" ]]; then
          IFS="," read -r -a _sf <<< "$SIZE_FILTER"
          _ok=0; for _s in "${_sf[@]}"; do [[ "$size" == "$_s" ]] && _ok=1 && break; done
          [[ $_ok -eq 1 ]] || continue
        fi

        if ! validate_combination "$series" "$type" "$size"; then
          append_skip "PRE:VALIDATION" "$series" "$type" "$size" "$offer" "$sku" "-" "Invalid combination series/type/size"
          continue
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

  configure_adaptive_timeouts "$LOCATION" "$size"
  detect_network_issues "$LOCATION"

  log "[$vm_name] Starting -> series=$series type=$type size=$size offer=$offer sku=$sku"
  log "[$vm_name] Label: $(label_for "$type" "$size") | Arch: $(arch_for "$type")"
  log "[$vm_name] Timeouts: SSH_RETRIES=$SSH_RETRIES, VM_POWER_RETRIES=$VM_POWER_RETRIES"
  
  local artifacts_dir="artifacts/${vm_name}"
  mkdir -p "$artifacts_dir"

  if vm_exists "$vm_name"; then
    log "[$vm_name] VM already exists."
  else
    log "[$vm_name] Creating VM ..."
    local create_log="${artifacts_dir}/_create_output.log"
    local arch; arch="$(arch_for "$type")"
    local label; label="$(label_for "$type" "$size")"

    if ! az vm create \
         --resource-group "$rg" \
         --name "$vm_name" \
         --image "${PUBLISHER:-Canonical}:$offer:$sku:${VERSION:-latest}" \
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
    
    # Register VM and associated resources for tracking
    local vm_id
    vm_id=$(az vm show -g "$rg" -n "$vm_name" --query id -o tsv 2>/dev/null || echo "")
    if [ -n "$vm_id" ] && command -v register_resource >/dev/null 2>&1; then
      register_resource "$vm_name" "vm" "$vm_id" "$vm_name"
    fi
  fi

  if ! wait_vm_running "$vm_name"; then
    append_skip "RUN:CREATE_POWER" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "VM did not reach running state"
    return 73
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
  local all_tests_passed=true
  
  for idx in $(seq 0 $((tests_count_local-1))); do
    tname=$(jq -r ".tests[$idx].name" "$CONFIG")
    local tdir="artifacts/${vm_name}/${tname}"
    mkdir -p "$tdir"
    local stdout_log="${tdir}/stdout.log"; : > "$stdout_log"

    log "[$vm_name] Running test '${tname}' ..."
    mapfile -t cmds < <(jq -r ".tests[$idx].commands[]?" "$CONFIG")
    test_status="GOOD"
    local bad_detail=""
    
    for line in "${cmds[@]}"; do
      if [[ "$line" == "#REBOOT#" ]]; then
        echo -e "\n${C_INFO}[TEST]${C_RESET} Requesting VM reboot ..." | tee -a "$stdout_log"
        restart_vm "$vm_name"
        if ! wait_ssh "$PUBLIC_IP"; then
          err "[$vm_name] SSH did not recover after reboot"
          append_skip "RUN:REBOOT_SSH" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "SSH did not recover after reboot"
          test_status="BAD"
          bad_detail="SSH connection lost after reboot"
          break
        fi
        continue
      fi
      
      echo -e "\n${C_CMD}[COMMAND]${C_RESET} $line" | tee -a "$stdout_log"
      set +e
      run_remote_with_retry "$PUBLIC_IP" "$line" 2 10 2>&1 | tee -a "$stdout_log"
      rc=${PIPESTATUS[0]}
      set -e
      
      if [ $rc -ne 0 ]; then
        echo "[ERROR] Command failed with exit code $rc" | tee -a "$stdout_log"
        case $rc in
          255)
            bad_detail="${bad_detail:+$bad_detail; }[CRITICAL] SSH_LOST exit=255 cmd=$(printf '%s' "$line" | tr '\n' ' ' | cut -c1-160)"
            ;;
          124)
            bad_detail="${bad_detail:+$bad_detail; }[CRITICAL] TIMEOUT exit=124 cmd=$(printf '%s' "$line" | tr '\n' ' ' | cut -c1-160)"
            ;;
          *)
            bad_detail="${bad_detail:+$bad_detail; }[ERROR] COMMAND_FAILED exit=$rc cmd=$(printf '%s' "$line" | tr '\n' ' ' | cut -c1-100)"
            ;;
        esac
        test_status="BAD"
        break
      fi
    done

    # Evaluate policies
    local pol_reason=""
    if ! pol_reason="$(evaluate_policies "$series" "$type" "$size" "$tname" "$vm_name" 2>&1)"; then
      test_status="BAD"
      bad_detail="${bad_detail:+$bad_detail; }${pol_reason}"
    fi

    # Print policy results
    if [ -n "$pol_reason" ]; then
      echo "$pol_reason" | tr ';' '\n' | sed 's/^ *//' | while read -r pl; do
        log "[$vm_name] $pl"
      done
    fi

    # Mark phase completion
    case "$tname" in
      phase1*) echo "METRIC:phase1_done=1" | tee -a "$stdout_log" ;;
      phase2*) echo "METRIC:phase2_done=1" | tee -a "$stdout_log" ;;
      phase3*) echo "METRIC:phase3_done=1" | tee -a "$stdout_log" ;;
    esac

    append_result "$test_status" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "$tname" "$stdout_log" "${bad_detail:-}"
    log "[$vm_name] Test '${tname}' -> ${test_status}"
    
    if [ "$test_status" = "BAD" ]; then
      all_tests_passed=false
      remaining=$((tests_count_local - idx - 1))
      warn "[$vm_name] Phase '${tname}' failed — aborting remaining ${remaining} phase(s) for this VM."
      if [ "$remaining" -gt 0 ]; then
        append_skip "RUN:ABORT_REST" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "Aborted remaining ${remaining} phase(s) after failure in '${tname}'"
      fi
      break
    fi
  done

  # Cleanup individual VM on success (optional, can be disabled)
  if [ "${CLEANUP_ON_SUCCESS:-0}" = "1" ] && [ "$KEEP_VMS" -eq 0 ] && [ "$all_tests_passed" = true ]; then
    log "[$vm_name] All tests completed successfully. Cleaning up VM..."
    if command -v cleanup_vm_comprehensive >/dev/null 2>&1 && cleanup_vm_comprehensive "$vm_name"; then
      log "[$vm_name] VM cleaned up successfully"
      # Remove from tracking file
      if [ -f "$CREATED_VMS_FILE" ]; then
        grep -v "^$vm_name$" "$CREATED_VMS_FILE" > "$CREATED_VMS_FILE.tmp" && \
          mv "$CREATED_VMS_FILE.tmp" "$CREATED_VMS_FILE" || true
      fi
    else
      warn "[$vm_name] VM cleanup had some issues, but test results are preserved"
    fi
  fi

  log "[$vm_name] Completed."
}

# Network cleanup functions
is_safe_to_delete_network() {
  local vm_name="$1" vnet_name="$2" subnet_name="$3" subnet_rg="$4" subnet_id="$5"
  
  local vm_lower vnet_lower
  vm_lower=$(echo "$vm_name" | tr "[:upper:]" "[:lower:]")
  vnet_lower=$(echo "$vnet_name" | tr "[:upper:]" "[:lower:]")
  
  # Check if VNet name matches VM pattern
  case "$vnet_lower" in
    "$vm_lower"|"$vm_lower-vnet"|"${vm_lower}vnet"|"t-"*"-vnet")
      : # Pattern matches, continue
      ;;
    *)
      log "VNet name $vnet_name doesn't match VM-specific pattern"
      return 1
      ;;
  esac
  
  local other_vms
  other_vms=$(az network nic list -g "$subnet_rg" --query "[?ipConfigurations[0].subnet.id=='$subnet_id'].{vm:virtualMachine.id}" -o tsv 2>/dev/null | grep -v "^$" | wc -l)
  if [ "$other_vms" -gt 0 ]; then
    warn "Subnet $subnet_name has $other_vms other VMs attached. Not safe to delete."
    return 1
  fi
  
  if [[ "$subnet_rg" != "$rg" && "$subnet_rg" != "NetworkWatcherRG" ]]; then
    warn "Subnet is in different resource group $subnet_rg. Not safe to delete."
    return 1
  fi
  
  local subnet_count
  subnet_count=$(az network vnet subnet list -g "$subnet_rg" --vnet-name "$vnet_name" --query "length(@)" -o tsv 2>/dev/null || echo 999)
  if [ "$subnet_count" -gt 3 ]; then
    warn "VNet $vnet_name has $subnet_count subnets. Likely shared infrastructure."
    return 1
  fi
  
  log "[$vm_name] Network cleanup safety checks passed for $vnet_name"
  return 0
}

cleanup_subnet_safely() {
  local vm_name="$1" subnet_rg="$2" vnet_name="$3" subnet_name="$4"
  
  log "[$vm_name] Attempting safe cleanup of subnet $subnet_name..."
  
  if az network vnet subnet delete -g "$subnet_rg" --vnet-name "$vnet_name" -n "$subnet_name" >/dev/null 2>&1; then
    log "[$vm_name] Subnet $subnet_name deleted successfully"
  else
    warn "[$vm_name] Failed to delete subnet $subnet_name"
    return 1
  fi
  
  local remaining_subnets
  remaining_subnets=$(az network vnet subnet list -g "$subnet_rg" --vnet-name "$vnet_name" --query "length(@)" -o tsv 2>/dev/null || echo 1)
  
  if [ "$remaining_subnets" -eq 0 ]; then
    log "[$vm_name] VNet $vnet_name is empty. Attempting deletion..."
    if az network vnet delete -g "$subnet_rg" -n "$vnet_name" >/dev/null 2>&1; then
      log "[$vm_name] VNet $vnet_name deleted successfully"
    else
      warn "[$vm_name] Failed to delete VNet $vnet_name (may have dependencies)"
    fi
  else
    log "[$vm_name] VNet $vnet_name still has $remaining_subnets subnets. Keeping it."
  fi
}

safe_network_cleanup() {
  local vm_name="$1" subnet_ids="$2"
  
  for subnet_id in $subnet_ids; do
    local subnet_rg vnet_name subnet_name
    subnet_rg=$(echo "$subnet_id" | awk -F"/" '{for(i=1;i<=NF;i++){if($i=="resourceGroups"){print $(i+1);break}}}')
    vnet_name=$(echo "$subnet_id" | awk -F"/" '{for(i=1;i<=NF;i++){if($i=="virtualNetworks"){print $(i+1);break}}}')
    subnet_name=$(echo "$subnet_id" | awk -F"/" '{for(i=1;i<=NF;i++){if($i=="subnets"){print $(i+1);break}}}')
    
    if ! is_safe_to_delete_network "$vm_name" "$vnet_name" "$subnet_name" "$subnet_rg" "$subnet_id"; then
      warn "[$vm_name] Skipping VNet cleanup for $vnet_name (failed safety checks)"
      continue
    fi
    
    cleanup_subnet_safely "$vm_name" "$subnet_rg" "$vnet_name" "$subnet_name"
  done
}

print_final_summary() {
  local results_log="$1" skip_log="$2"

  local GOOD_CNT BAD_CNT SKIP_CNT
  GOOD_CNT=$(grep -c '^GOOD|' "$results_log" 2>/dev/null || echo 0)
  BAD_CNT=$(grep -c '^BAD|'  "$results_log"  2>/dev/null || echo 0)
  SKIP_CNT=$(wc -l < "$skip_log" 2>/dev/null | tr -d ' ' || echo 0)

  printf "%b==== FINAL SUMMARY (GOOD / BAD / SKIP) ====%b\n" "${C_INFO:-}" "${C_RESET:-}"
  printf "%bGOOD: %s%b\n" "${C_GOOD:-}" "${GOOD_CNT}" "${C_RESET:-}"
  printf "%bBAD:  %s%b\n" "${C_ERR:-}" "${BAD_CNT}" "${C_RESET:-}"
  printf "%bSKIP: %s%b\n" "${C_WARN:-}" "${SKIP_CNT}" "${C_RESET:-}"

  count_skip_code() { 
    awk -F'|' -v code="$1" '$1==code{n++} END{print n+0}' "$skip_log" 2>/dev/null
  }
  
  CRIT_CREATE=$(count_skip_code 'RUN:CREATE')
  CRIT_IP=$(count_skip_code 'RUN:IP')
  CRIT_SSH=$(count_skip_code 'RUN:SSH')
  CRIT_REBOOT=$(count_skip_code 'RUN:REBOOT_SSH')
  CRIT_POWER=$(count_skip_code 'RUN:REBOOT_POWER')
  CRIT_CREATE_POWER=$(count_skip_code 'RUN:CREATE_POWER')
  CRIT_ABORT=$(count_skip_code 'RUN:ABORT_REST')
  CRIT_SSH_LOST=$(count_skip_code 'RUN:SSH_LOST')
  CRIT_VALIDATION=$(count_skip_code 'PRE:VALIDATION')
  CRIT_TOTAL=$((CRIT_CREATE + CRIT_IP + CRIT_SSH + CRIT_REBOOT + CRIT_POWER + CRIT_CREATE_POWER + CRIT_ABORT + CRIT_SSH_LOST + CRIT_VALIDATION))

  printf "%b-- CRITICAL SKIPS --%b\n" "${C_WARN:-}" "${C_RESET:-}"
  printf "PRE:VALIDATION = %d\n" "$CRIT_VALIDATION"
  printf "RUN:CREATE     = %d\n" "$CRIT_CREATE"
  printf "RUN:CREATE_POWER = %d\n" "$CRIT_CREATE_POWER"
  printf "RUN:IP         = %d\n" "$CRIT_IP"
  printf "RUN:SSH        = %d\n" "$CRIT_SSH"
  printf "RUN:SSH_LOST   = %d\n" "$CRIT_SSH_LOST"
  printf "RUN:REBOOT_SSH = %d\n" "$CRIT_REBOOT"
  printf "RUN:ABORT_REST = %d\n" "$CRIT_ABORT"
  printf "TOTAL CRITICAL = %d\n" "$CRIT_TOTAL"
  
  if [ "$CRIT_TOTAL" -gt 0 ]; then
    printf "%b-- Critical SKIP details --%b\n" "${C_WARN:-}" "${C_RESET:-}"
    grep -E '^(PRE:VALIDATION|RUN:CREATE|RUN:CREATE_POWER|RUN:IP|RUN:SSH|RUN:SSH_LOST|RUN:REBOOT_SSH)\|' "$skip_log" 2>/dev/null || true
  fi

  if [ "$GOOD_CNT" -gt 0 ]; then
    printf "%b-- GOOD details --%b\n" "${C_GOOD:-}" "${C_RESET:-}"
    grep '^GOOD|' "$results_log" 2>/dev/null || true
  fi
  if [ "$BAD_CNT" -gt 0 ]; then
    printf "%b-- BAD details --%b\n" "${C_ERR:-}" "${C_RESET:-}"
    grep '^BAD|' "$results_log" 2>/dev/null || true
  fi
  if [ "$SKIP_CNT" -gt 0 ]; then
    printf "%b-- SKIP details (all) --%b\n" "${C_WARN:-}" "${C_RESET:-}"
    cat "$skip_log" 2>/dev/null || true
  fi
}