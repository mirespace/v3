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
  ssh -i "$SSH_PRIV_DEFAULT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "${ADMIN_USER:-ubuntu}@${ip}" "set -eo pipefail; ${cmd}"
}

append_skip() {
  printf "%s|series=%s|type=%s|size=%s|offer=%s|sku=%s|vm=%s|%s\n" \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$SKIP_LOG"
}

append_result() {
  printf "%s|series=%s|type=%s|size=%s|offer=%s|sku=%s|vm=%s|test=%s|%s\n" \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >> "$RESULTS_LOG"
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

evaluate_policies() {
  local series="$1" type="$2" size="$3" tname="$4" vm="$5"
  local metrics; metrics=$(collect_metrics_for_vm "$vm")

  getm() { printf '%s' "$metrics" | jq -r --arg k "$1" '.[$k] // empty'; }

  local has_v2 has_legacy has_mana has_mlx aznvme initrd_rules proposed dbg ver
  has_v2=$(getm has_nvme_v2)
  has_legacy=$(getm has_nvme_legacy)
  has_mana=$(getm net_has_mana)
  has_mlx=$(getm net_has_mlx)
  aznvme=$(getm azure_nvme_id_ok)
  initrd_rules=$(getm initrd_azure_rules)
  proposed=$(getm proposed_enabled)
  dbg=$(getm networkd_debug)
  ver=$(getm azure_vm_utils_version)

  nz() { echo "${1:-0}"; }

  local fail_reason=""

  case "$type:$size" in
    amd64_*:Standard_E2ads_v6)
      if [ "$(nz "$has_v2")" -eq 0 ] && [ "$(nz "$has_legacy")" -eq 0 ]; then
        fail_reason="E2ads_v6 should expose NVMe (v2 or legacy)"
      elif [ "$(nz "$has_mlx")" -eq 0 ]; then
        fail_reason="E2ads_v6 expects Mellanox (mlx) networking present"
      fi
      ;;
    amd64_*:Standard_D2alds_v6)
      if [ "$(nz "$has_legacy")" -eq 0 ]; then
        fail_reason="D2alds_v6 should expose legacy NVMe (Microsoft NVMe Direct Disk)"
      fi
      ;;
    amd64_*:Standard_D2ls_v6)
      if [ "$(nz "$has_mana")" -eq 0 ]; then
        fail_reason="D2ls_v6 should expose Net MANA driver"
      fi
      ;;
    arm64_*:Standard_E2pds_v6|arm64_*:Standard_D2pds_v6|arm64_*:Standard_D2plds_v6)
      if [ "$(nz "$has_v2")" -eq 0 ] && [ "$(nz "$has_legacy")" -eq 0 ]; then
        fail_reason="ARM64 Cobalt NVMe sizes should expose NVMe (v2 or legacy)"
      fi
      ;;
  esac

  if [ "$(nz "$has_v2")" -eq 1 ]; then
    if [ "$(nz "$aznvme")" -ne 1 ]; then
      fail_reason="${fail_reason:+$fail_reason; }azure-nvme-id --udev should succeed when NVMe v2 is present"
    fi
    if [ -n "$initrd_rules" ] && [ "$(nz "$initrd_rules")" -lt 1 ]; then
      fail_reason="${fail_reason:+$fail_reason; }initrd should contain Azure udev rules when NVMe v2 is present"
    fi
  fi

  if [ -n "$proposed" ] && [ "$(nz "$proposed")" -ne 1 ]; then
    fail_reason="${fail_reason:+$fail_reason; }-proposed should be enabled (proposed_enabled=1)"
  fi
  if [ -n "$dbg" ] && [ "$(nz "$dbg")" -ne 1 ]; then
    fail_reason="${fail_reason:+$fail_reason; }systemd-networkd debug should be enabled"
  fi
  if [ -n "$ver" ] && [ "$ver" = "unknown" ]; then
    fail_reason="${fail_reason:+$fail_reason; }azure-vm-utils should be installed from -proposed"
  fi

  if [ -n "$fail_reason" ]; then
    echo "$fail_reason"
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
  tests_count_local=$(jq '.tests | length' "$CONFIG")
  for idx in $(seq 0 $((tests_count_local-1))); do
    local tname; tname=$(jq -r ".tests[$idx].name" "$CONFIG")
    local tdir="artifacts/${vm_name}/${tname}"
    mkdir -p "$tdir"
    local stdout_log="${tdir}/stdout.log"; : > "$stdout_log"

    log "[$vm_name] Running test '${tname}' ..."
    mapfile -t cmds < <(jq -r ".tests[$idx].commands[]?" "$CONFIG")
    test_status="GOOD"
    for line in "${cmds[@]}"; do
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
        test_status="BAD"
        break  # abort current phase on first failure
      fi
    done

    # Policy evaluation (uses merged metrics across phases)
    pol_reason=$(evaluate_policies "$series" "$type" "$size" "$tname" "$vm_name" || true)
    if [ -n "$pol_reason" ]; then
      test_status="BAD"
      echo "[POLICY] $pol_reason" | tee -a "$stdout_log"
    fi

    append_result "$test_status" "$series" "$type" "$size" "$offer" "$sku" "$vm_name" "$tname" "completed"
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
  GOOD_CNT=$(grep -c '^GOOD|' "$results_log" 2>/dev/null || true)
  BAD_CNT=$(grep -c '^BAD|'  "$results_log"  2>/dev/null || true)
  SKIP_CNT=$(wc -l < "$skip_log" 2>/dev/null | tr -d ' ' || echo 0)

  printf "%b==== FINAL SUMMARY (GOOD / BAD / SKIP) ====%b\n" "${C_INFO}" "${C_RESET}"
  printf "%bGOOD: %s%b\n" "${C_GOOD:-$C_INFO}" "${GOOD_CNT}" "${C_RESET}"
  printf "%bBAD:  %s%b\n" "${C_ERR}" "${BAD_CNT}" "${C_RESET}"
  printf "%bSKIP: %s%b\n" "${C_WARN}" "${SKIP_CNT}" "${C_RESET}"

  count_skip_code() { awk -F'|' -v code="$1" '$1==code{n++} END{print n+0}' "$skip_log" 2>/dev/null; }
  CRIT_CREATE=$(count_skip_code 'RUN:CREATE')
  CRIT_IP=$(count_skip_code 'RUN:IP')
  CRIT_SSH=$(count_skip_code 'RUN:SSH')
  CRIT_REBOOT=$(count_skip_code 'RUN:REBOOT_SSH')
  CRIT_POWER=$(count_skip_code 'RUN:REBOOT_POWER')
  CRIT_CREATE_POWER=$(count_skip_code 'RUN:CREATE_POWER')
  CRIT_ABORT=$(count_skip_code 'RUN:ABORT_REST')
  CRIT_TOTAL=$(( CRIT_CREATE + CRIT_IP + CRIT_SSH + CRIT_REBOOT + CRIT_POWER + CRIT_CREATE_POWER + CRIT_ABORT ))

  printf "%b-- CRITICAL SKIPS --%b\n" "${C_WARN}" "${C_RESET}"
  printf "RUN:CREATE     = %d\n" "$CRIT_CREATE"
  printf "RUN:IP         = %d\n" "$CRIT_IP"
  printf "RUN:SSH        = %d\n" "$CRIT_SSH"
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
  fi
  if [ "$SKIP_CNT" -gt 0 ]; then
    printf "%b-- SKIP details (all) --%b\n" "${C_WARN}" "${C_RESET}"
    cat "$skip_log"
  fi
}
