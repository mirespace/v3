#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm_test_lib.sh
source "$SCRIPT_DIR/lib/vm_test_lib.sh"
# shellcheck source=lib/bootstrap.sh
source "$SCRIPT_DIR/lib/bootstrap.sh"

print_help() {
  local cfg="${1:-}"
  cat <<'EOF'
Usage:
  ./run-tests.sh <config.json> [options]

Options:
  --series <name|all>         Filter matrix by series (from JSON)
  --arch amd|arm|all          Filter by architecture (optional; inferred from --type if omitted)
  --type <a,b,c|all>          Filter by type(s) (from JSON), comma-separated
  --size <a,b,c|all>          Filter by size(s) (from JSON), comma-separated
  --max-parallel <N>          Max concurrent VMs (default: 1)
  --json [path]               Emit artifacts/summary.json (or custom path)
  --keep-vms                  Do NOT delete VMs at the end (for debugging)
  --cleanup-network           Also attempt subnet/VNet cleanup (safe heuristic)
  -h, --help                  Show this help. If <config.json> is provided, list accepted values

Notes:
  * Values for series/types/sizes are extracted from the provided JSON.
  * --type/--size accept comma-separated lists.
EOF

  cat <<'EOT'

What is --size for?
  --size selects the actual Azure VM SKU (capacity, region availability, pricing).
  Labels are descriptive (driver expectations) and are used in VM names and tags.

Size -> Label (driver intent)
  AMD64:
    Standard_E2ads_v6   -> nvme2-mlx        (NVMe v2 + Mellanox NIC)
    Standard_D2alds_v6  -> nvme1            (Legacy NVMe)
    Standard_D2ls_v6    -> mana             (MANA NIC focus)
  ARM64 (Cobalt 100):
    Standard_E2pds_v6   -> nvme2-arm64      (NVMe v2)
    Standard_D2pds_v6   -> nvme1-arm64      (Legacy NVMe)
    Standard_D2plds_v6  -> nvme1-arm64-2g   (Legacy NVMe, 2 GiB/vCPU)
EOT
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    echo ""
    echo "From config: $cfg"
    echo "Accepted values:"
    echo "  series:"
    jq -r '.matrix.series[] | "    - \(. )"' "$cfg"
    echo "  types:"
    jq -r '.matrix.types[]  | "    - \(. )"' "$cfg"
    echo "  sizes:"
    jq -r '.matrix.sizes[]  | "    - \(. )"' "$cfg"
    echo "  image_catalog (series/type -> offer:sku):"
    jq -r '.image_catalog[] | "    - \(.series)/\(.type) -> \(.offer):\(.sku)"' "$cfg"

    echo ""
    echo "Examples:"
    series_j=$(jq -r '([.matrix.series[] | select(.=="jammy")] + [.matrix.series[0]])[0]' "$cfg")
    series_a=$(jq -r '([.matrix.series[] | select(.=="noble")] + [.matrix.series[0]])[0]' "$cfg")

    amd_type=$(jq -r '([.matrix.types[] | select(startswith("amd64_server"))] + [.matrix.types[] | select(startswith("amd64_"))] + [.matrix.types[0]])[0]' "$cfg")
    arm_type=$(jq -r '([.matrix.types[] | select(startswith("arm64_server"))] + [.matrix.types[] | select(startswith("arm64_"))] + [.matrix.types[0]])[0]' "$cfg")

    amd_size=$(jq -r '([.matrix.sizes[] | select(.=="Standard_E2ads_v6")] + [.matrix.sizes[0]])[0]' "$cfg")
    arm_size=$(jq -r '([.matrix.sizes[] | select(.=="Standard_E2pds_v6")] + [.matrix.sizes[] | select(contains("pds"))] + [.matrix.sizes[0]])[0]' "$cfg")

    echo "  # AMD example: run jammy on amd64_server with E2ads_v6 (NVMe+mlx) and JSON:"
    echo "  ./run-tests.sh $cfg --series ${series_j} --type ${amd_type} --size ${amd_size} --max-parallel 1 --json"
    echo ""
    echo "  # ARM example: run noble on arm64_server with E2pds_v6 (Cobalt NVMe) and JSON:"
    echo "  ./run-tests.sh $cfg --series ${series_a} --type ${arm_type} --size ${arm_size} --max-parallel 1 --json"
    echo ""
    echo "  # Quick: run jammy on ${amd_type} across ALL sizes (arch inferred from type):"
    echo "  ./run-tests.sh $cfg --series ${series_j} --type ${amd_type} --max-parallel 1 --json"
    echo ""
    echo "  # Tip: --arch is optional; when omitted, it is inferred from --type."
  else
    echo ""
    echo "Tip: pass a config file to list accepted values, e.g.:"
    echo "  ./run-tests.sh tests-matrix.json --help"
  fi
}

# Defaults
PUBLISHER="${PUBLISHER:-Canonical}"
VERSION="${VERSION:-latest}"
ADMIN_USER="${ADMIN_USER:-ubuntu}"
SSH_PUB_DEFAULT="${SSH_PUB_DEFAULT:-$HOME/.ssh/id_rsa.pub}"
SSH_PRIV_DEFAULT="${SSH_PRIV_DEFAULT:-${SSH_PUB_DEFAULT%.pub}}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-6}"
SSH_RETRIES="${SSH_RETRIES:-40}"
SSH_SLEEP="${SSH_SLEEP:-5}"

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then print_help; exit 0; fi
CONFIG="${1-}"; shift 1 || true
[ -f "${CONFIG:-}" ] || { err "Config file not found: ${CONFIG:-<missing>}"; exit 64; }

# Flags
SERIES_FILTER="all"
MAX_PARALLEL=1
ENABLE_JSON_SUMMARY=0
JSON_OUT="artifacts/summary.json"
ARCH_FILTER="all"
TYPE_FILTER="all"
SIZE_FILTER="all"
CLEANUP_NETWORK=0
KEEP_VMS=0
HELP_FLAG=0


# Parse args
while (( "$#" )); do
  case "$1" in
    --series)       SERIES_FILTER="${2-}"; shift 2 ;;
    --max-parallel) MAX_PARALLEL="${2-}"; shift 2 ;;
    --arch)         ARCH_FILTER="${2-}";  shift 2 ;;
    --type)         TYPE_FILTER="${2-}";  shift 2 ;;
    --size)         SIZE_FILTER="${2-}";  shift 2 ;;
    --keep-vms)     KEEP_VMS=1;           shift 1 ;;
    --cleanup-network) CLEANUP_NETWORK=1; shift 1 ;;
    --json|--json=*)
      ENABLE_JSON_SUMMARY=1
      if [[ "$1" == --json=* ]]; then
        val="${1#--json=}"
        JSON_OUT="${val:-$JSON_OUT}"
        shift 1
      else
        if [[ "${2-}" != "" && "${2:0:1}" != "-" ]]; then
          JSON_OUT="${2}"; shift 2
        else
          shift 1
        fi
      fi
      ;;
    -h|--help) HELP_FLAG=1; shift 1 ;;
    *) err "Unknown argument: $1"; exit 64 ;;
  esac
done

[[ "$MAX_PARALLEL" =~ ^[0-9]+$ ]] && [ "$MAX_PARALLEL" -ge 1 ] || { err "--max-parallel must be a positive integer"; exit 64; }
case "$ARCH_FILTER" in amd|arm|all) : ;; *) err "--arch must be one of: amd, arm, all"; exit 64 ;; esac

# Contextual help
if [ "$HELP_FLAG" -eq 1 ]; then
  if [ -f "${CONFIG:-}" ]; then print_help "$CONFIG"; else print_help; fi
  exit 0
fi

# Infer ARCH from TYPE if ARCH not explicitly set and TYPE is provided
if [[ "$ARCH_FILTER" == "all" && "${TYPE_FILTER:-all}" != "all" ]]; then
  IFS="," read -r -a _tf <<< "$TYPE_FILTER"
  _guess=""
  for _t in "${_tf[@]}"; do
    if [[ "$_t" == arm64_* ]]; then _cur="arm"
    elif [[ "$_t" == amd64_* ]]; then _cur="amd"
    else _cur=""
    fi
    if [[ -z "$_guess" ]]; then _guess="$_cur"
    elif [[ "$_guess" != "$_cur" ]]; then _guess="mixed"; break
    fi
  done
  if [[ "$_guess" == "arm" || "$_guess" == "amd" ]]; then
    ARCH_FILTER="$_guess"
    log "Arch filter inferred from --type: $ARCH_FILTER"
  fi
fi

if [ "$ENABLE_JSON_SUMMARY" -eq 1 ]; then
  log "JSON summary enabled. Output file: $JSON_OUT"
fi
log "Arch filter: $ARCH_FILTER"
log "Type filter: $TYPE_FILTER"
log "Size filter: $SIZE_FILTER"
[ "$CLEANUP_NETWORK" -eq 1 ] && log "Cleanup network: enabled" || log "Cleanup network: disabled"
[ "$KEEP_VMS" -eq 1 ] && warn "KEEP_VMS enabled: resources will NOT be deleted at the end." || :

# Bootstrap
bootstrap_all "$SSH_PUB_DEFAULT" "$SSH_PRIV_DEFAULT"

# Read config
rg=$(jq -r '.resource_group' "$CONFIG")
vm_name_pattern=$(jq -r '.vm_name_pattern // "t-{series}-{type}-{size}"' "$CONFIG")
[ -n "$rg" ] || { err "'resource_group' missing"; exit 65; }
LOCATION=$(az group show --name "$rg" --query "location" -o tsv 2>/dev/null || true)
[ -n "$LOCATION" ] || { err "Resource group '$rg' does not exist or is not accessible"; exit 65; }
log "Resource group: $rg (location: $LOCATION)"

readarray -t SERIES < <(jq -r '.matrix.series[]' "$CONFIG")
readarray -t TYPES  < <(jq -r '.matrix.types[]'  "$CONFIG")
readarray -t SIZES  < <(jq -r '.matrix.sizes[]'  "$CONFIG")
tests_count=$(jq '.tests | length' "$CONFIG")
[ "$tests_count" -gt 0 ] || { err "No tests defined"; exit 65; }

# Logs
mkdir -p artifacts
SKIP_LOG="artifacts/_skip_summary.log"
RESULTS_LOG="artifacts/_results_summary.log"
CREATED_VMS_FILE="artifacts/_created_vms.list"
: > "$SKIP_LOG"; : > "$RESULTS_LOG"; : > "$CREATED_VMS_FILE"

# Worklist
declare -a WORKLIST=()
build_worklist "$SERIES_FILTER" "$rg" "$LOCATION" WORKLIST

if [ "${#WORKLIST[@]}" -eq 0 ]; then
  warn "No matching combinations after filtering."
  print_final_summary "$RESULTS_LOG" "$SKIP_LOG"
  if [ "$ENABLE_JSON_SUMMARY" -eq 1 ]; then
    # shellcheck source=lib/json_summary.sh
    source "$SCRIPT_DIR/lib/json_summary.sh"
    mkdir -p "$(dirname "$JSON_OUT")"
    write_summary_json "$JSON_OUT" "$RESULTS_LOG" "$SKIP_LOG" "$rg" "$LOCATION" "$SERIES_FILTER" "$MAX_PARALLEL"
    log "Saved JSON summary to: $JSON_OUT"
  fi
  exit 0
fi

export PUBLISHER VERSION ADMIN_USER SSH_PUB_DEFAULT SSH_PRIV_DEFAULT rg LOCATION CONFIG CREATED_VMS_FILE ARCH_FILTER TYPE_FILTER SIZE_FILTER CLEANUP_NETWORK \
       SSH_CONNECT_TIMEOUT SSH_RETRIES SSH_SLEEP vm_name_pattern SKIP_LOG RESULTS_LOG SERIES_FILTER MAX_PARALLEL

export -f log warn err catalog_lookup slugify label_for arch_for wait_vm_running metrics_from_file collect_metrics_for_vm evaluate_policies \
          vm_exists wait_ssh restart_vm run_remote \
          append_skip append_result run_combo

# Parallel exec
active_jobs() { jobs -rp | wc -l | tr -d ' '; }

for tuple in "${WORKLIST[@]}"; do
  IFS='|' read -r series type size offer sku vm_name <<<"$tuple"
  while [ "$(active_jobs)" -ge "$MAX_PARALLEL" ]; do sleep 1; done
  bash -c "run_combo \"$series\" \"$type\" \"$size\" \"$offer\" \"$sku\" \"$vm_name\"" &
done
wait

# Summary
print_final_summary "$RESULTS_LOG" "$SKIP_LOG"

# JSON
if [ "$ENABLE_JSON_SUMMARY" -eq 1 ]; then
  # shellcheck source=lib/json_summary.sh
  source "$SCRIPT_DIR/lib/json_summary.sh"
  mkdir -p "$(dirname "$JSON_OUT")"
  write_summary_json "$JSON_OUT" "$RESULTS_LOG" "$SKIP_LOG" "$rg" "$LOCATION" "$SERIES_FILTER" "$MAX_PARALLEL"
  log "Saved JSON summary to: $JSON_OUT"
fi

# Cleanup VMs (and optional network) unless KEEP_VMS
cleanup_created_vms() {
  if [ ! -s "$CREATED_VMS_FILE" ]; then
    log "No VMs to cleanup."
    return 0
  fi
  log "Starting cleanup of created VMs..."
  while IFS= read -r VM; do
    [ -z "$VM" ] && continue
    log "[$VM] Collecting attached resources for deletion..."
    VM_JSON=$(az vm show -g "$rg" -n "$VM" -d -o json 2>/dev/null || true)
    if [ -z "$VM_JSON" ]; then
      warn "[$VM] VM not found (maybe already deleted). Skipping."
      continue
    fi
    OS_DISK_ID=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.managedDisk.id // empty')
    DATA_DISK_IDS=$(echo "$VM_JSON" | jq -r '.storageProfile.dataDisks[].managedDisk.id // empty')
    NIC_IDS=$(echo "$VM_JSON" | jq -r '.networkProfile.networkInterfaces[].id // empty')

    PIP_IDS=""; NSG_IDS=""; SUBNET_IDS=""
    for NIC in $NIC_IDS; do
      NIC_JSON=$(az network nic show --ids "$NIC" -o json 2>/dev/null || true)
      [ -z "$NIC_JSON" ] && continue
      PIPS=$(echo "$NIC_JSON" | jq -r '.ipConfigurations[].publicIpAddress.id // empty')
      [ -n "$PIPS" ] && PIP_IDS="$PIP_IDS $PIPS"
      NSG=$(echo "$NIC_JSON" | jq -r '.networkSecurityGroup.id // empty')
      [ -n "$NSG" ] && NSG_IDS="$NSG_IDS $NSG"
      SUBNET=$(echo "$NIC_JSON" | jq -r '.ipConfigurations[].subnet.id // empty' | head -n1)
      [ -n "$SUBNET" ] && SUBNET_IDS="$SUBNET_IDS $SUBNET"
    done

    log "[$VM] Deleting VM..."
    az vm delete -g "$rg" -n "$VM" --yes >/dev/null 2>&1 || warn "[$VM] az vm delete failed."

    [ -n "$OS_DISK_ID" ] && { log "[$VM] Deleting OS disk..."; az disk delete --ids "$OS_DISK_ID" --yes >/dev/null 2>&1 || warn "[$VM] OS disk delete failed"; }
    for DID in $DATA_DISK_IDS; do [ -n "$DID" ] && { log "[$VM] Deleting data disk $DID ..."; az disk delete --ids "$DID" --yes >/dev/null 2>&1 || true; }; done
    for NIC in $NIC_IDS; do [ -n "$NIC" ] && { log "[$VM] Deleting NIC $NIC ..."; az network nic delete --ids "$NIC" >/dev/null 2>&1 || true; }; done
    for PIP in $PIP_IDS; do [ -n "$PIP" ] && { log "[$VM] Deleting Public IP $PIP ..."; az network public-ip delete --ids "$PIP" >/dev/null 2>&1 || true; }; done
    for NSG in $NSG_IDS; do [ -n "$NSG" ] && { log "[$VM] Deleting NSG $NSG ..."; az network nsg delete --ids "$NSG" >/dev/null 2>&1 || true; }; done

    if [ "${CLEANUP_NETWORK:-0}" -eq 1 ]; then
      for SUB in $SUBNET_IDS; do
        SUB_RG=$(echo "$SUB" | awk -F"/" '{for(i=1;i<=NF;i++){if($i=="resourceGroups"){print $(i+1);break}}}')
        VNET_NAME=$(echo "$SUB" | awk -F"/" '{for(i=1;i<=NF;i++){if($i=="virtualNetworks"){print $(i+1);break}}}')
        SUBNET_NAME=$(echo "$SUB" | awk -F"/" '{for(i=1;i<=NF;i++){if($i=="subnets"){print $(i+1);break}}}')
        LVM=$(echo "$VM" | tr "[:upper:]" "[:lower:]")
        LVN=$(echo "$VNET_NAME" | tr "[:upper:]" "[:lower:]")
        if [[ "$LVN" == "$LVM" || "$LVN" == "$LVM-vnet" || "$LVN" == "$LVMvnet" ]]; then
          log "[$VM] Deleting subnet $SUBNET_NAME in VNet $VNET_NAME ..."
          az network vnet subnet delete -g "$SUB_RG" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" >/dev/null 2>&1 || true
          log "[$VM] Trying to delete VNet $VNET_NAME ..."
          az network vnet delete -g "$SUB_RG" -n "$VNET_NAME" >/dev/null 2>&1 || true
        else
          warn "[$VM] Skipping VNet $VNET_NAME (does not match safe heuristic for VM name)"
        fi
      done
    fi

    log "[$VM] Cleanup done."
  done < "$CREATED_VMS_FILE"
}

if [ "$KEEP_VMS" -eq 0 ]; then
  cleanup_created_vms
else
  warn "Skipping cleanup due to --keep-vms."
fi

# Exit code for CI
BAD_CNT=$(grep -c '^BAD|' "$RESULTS_LOG" 2>/dev/null || true)
if [ "$BAD_CNT" -gt 0 ]; then
  err "There are BAD tests. Failing with exit code 1."
  exit 1
fi

log "Matrix run finished. See ./artifacts/"
exit 0
