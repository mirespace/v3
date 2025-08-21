#!/bin/bash
# run-tests.sh - Versión completa con limpieza robusta
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===== LOGGING BÁSICO (definido temprano) =====
CORRELATION_ID=$(date +%s)-$$

log_info() { 
  printf '[%s] INFO [%s] %s (cid:%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%S)" "${1:-main}" "${2:-$1}" "$CORRELATION_ID"
}
log_warn() { 
  printf '[%s] WARN [%s] %s (cid:%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%S)" "${1:-main}" "${2:-$1}" "$CORRELATION_ID"
}
log_error() { 
  printf '[%s] ERROR [%s] %s (cid:%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%S)" "${1:-main}" "${2:-$1}" "$CORRELATION_ID" >&2
}

# ===== FUNCIONES DE AYUDA =====
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
  --dry-run                   Show what would be executed without creating VMs
  --timeout-multiplier <N>    Multiply base timeouts by this factor (default: 1.0)
  -h, --help                  Show this help. If <config.json> is provided, list accepted values

Notes:
  * Values for series/types/sizes are extracted from the provided JSON.
  * --type/--size accept comma-separated lists.
  * --dry-run is useful for validating configurations.
EOF

  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    echo ""
    echo "From config: $cfg"
    echo "Accepted values:"
    echo "  series:"
    jq -r '.matrix.series[] | "    - \(. )"' "$cfg" 2>/dev/null || echo "    (error reading config)"
    echo "  types:"
    jq -r '.matrix.types[]  | "    - \(. )"' "$cfg" 2>/dev/null || echo "    (error reading config)"
    echo "  sizes:"
    jq -r '.matrix.sizes[]  | "    - \(. )"' "$cfg" 2>/dev/null || echo "    (error reading config)"
  else
    echo ""
    echo "Tip: pass a config file to list accepted values, e.g.:"
    echo "  ./run-tests.sh tests-matrix.json --help"
  fi
}

# ===== VALIDACIÓN TEMPRANA =====
# Defaults
PUBLISHER="${PUBLISHER:-Canonical}"
VERSION="${VERSION:-latest}"
ADMIN_USER="${ADMIN_USER:-ubuntu}"
SSH_PUB_DEFAULT="${SSH_PUB_DEFAULT:-$HOME/.ssh/id_rsa.pub}"
SSH_PRIV_DEFAULT="${SSH_PRIV_DEFAULT:-${SSH_PUB_DEFAULT%.pub}}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-10}"
SSH_RETRIES="${SSH_RETRIES:-40}"
SSH_SLEEP="${SSH_SLEEP:-5}"

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then print_help; exit 0; fi
CONFIG="${1-}"; shift 1 || true
[ -f "${CONFIG:-}" ] || { log_error "main" "Config file not found: ${CONFIG:-<missing>}"; exit 64; }

# Basic validation
if ! command -v jq >/dev/null 2>&1; then
  log_error "main" "jq is required but not installed"
  exit 69
fi

if ! jq empty "$CONFIG" 2>/dev/null; then
  log_error "main" "Invalid JSON in config file: $CONFIG"
  exit 65
fi

# Flags with defaults
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
DRY_RUN=0
TIMEOUT_MULTIPLIER=1.0

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
    --dry-run)      DRY_RUN=1;            shift 1 ;;
    --timeout-multiplier) TIMEOUT_MULTIPLIER="${2:-1.0}"; shift 2 ;;
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
    *) log_error "main" "Unknown argument: $1"; exit 64 ;;
  esac
done

# Validate arguments
if [[ ! "$MAX_PARALLEL" =~ ^[0-9]+$ ]] || [ "$MAX_PARALLEL" -lt 1 ]; then
  log_error "main" "--max-parallel must be a positive integer"
  exit 64
fi

# Fix timeout multiplier validation
if ! echo "$TIMEOUT_MULTIPLIER" | grep -Eq '^[0-9]+(\.[0-9]+)?$'; then
  log_error "main" "--timeout-multiplier must be a positive number, got: '$TIMEOUT_MULTIPLIER'"
  exit 64
fi

case "$ARCH_FILTER" in 
  amd|arm|all) : ;; 
  *) log_error "main" "--arch must be one of: amd, arm, all"; exit 64 ;; 
esac

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
    log_info "main" "Arch filter inferred from --type: $ARCH_FILTER"
  fi
fi

# Logging inicial
log_info "main" "Starting azure-vm-utils test orchestrator (correlation_id: $CORRELATION_ID)"
[ "$DRY_RUN" -eq 1 ] && log_info "main" "DRY RUN MODE - No VMs will be created"
[ "$ENABLE_JSON_SUMMARY" -eq 1 ] && log_info "main" "JSON summary enabled. Output file: $JSON_OUT"
log_info "main" "Filters - Arch: $ARCH_FILTER, Type: $TYPE_FILTER, Size: $SIZE_FILTER"
[ "$CLEANUP_NETWORK" -eq 1 ] && log_info "main" "Network cleanup enabled" || log_info "main" "Network cleanup disabled"
[ "$KEEP_VMS" -eq 1 ] && log_warn "main" "KEEP_VMS enabled: resources will NOT be deleted" || :

# ===== RESOURCE TRACKING SYSTEM =====
CREATED_RESOURCES_FILE="artifacts/_created_resources.json"

# Función para registrar recursos creados
register_resource() {
  local vm_name="$1" resource_type="$2" resource_id="$3" resource_name="$4"
  
  mkdir -p artifacts
  local timestamp; timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  # Crear entrada JSON para el recurso
  local resource_entry
  resource_entry=$(jq -n \
    --arg vm "$vm_name" \
    --arg type "$resource_type" \
    --arg id "$resource_id" \
    --arg name "$resource_name" \
    --arg ts "$timestamp" \
    '{
      vm: $vm,
      type: $type, 
      id: $id,
      name: $name,
      created_at: $ts,
      status: "active"
    }')
  
  # Agregar al archivo de recursos (crear si no existe)
  if [ ! -f "$CREATED_RESOURCES_FILE" ]; then
    echo "[]" > "$CREATED_RESOURCES_FILE"
  fi
  
  # Agregar nueva entrada
  jq --argjson entry "$resource_entry" '. + [$entry]' "$CREATED_RESOURCES_FILE" > "$CREATED_RESOURCES_FILE.tmp" && \
    mv "$CREATED_RESOURCES_FILE.tmp" "$CREATED_RESOURCES_FILE"
  
  log_info "resource" "Registered $resource_type for VM $vm_name: $resource_name"
}

# Función para marcar recurso como eliminado
mark_resource_deleted() {
  local resource_id="$1"
  
  if [ -f "$CREATED_RESOURCES_FILE" ]; then
    jq --arg id "$resource_id" '
      map(if .id == $id then . + {status: "deleted", deleted_at: now | strftime("%Y-%m-%dT%H:%M:%SZ")} else . end)
    ' "$CREATED_RESOURCES_FILE" > "$CREATED_RESOURCES_FILE.tmp" && \
      mv "$CREATED_RESOURCES_FILE.tmp" "$CREATED_RESOURCES_FILE"
  fi
}

# Función para obtener recursos activos de una VM
get_vm_resources() {
  local vm_name="$1"
  
  if [ ! -f "$CREATED_RESOURCES_FILE" ]; then
    echo "[]"
    return 0
  fi
  
  jq --arg vm "$vm_name" '
    map(select(.vm == $vm and .status == "active"))
  ' "$CREATED_RESOURCES_FILE"
}

# ===== COMPREHENSIVE CLEANUP FUNCTIONS =====

# Función de limpieza comprehensiva por VM
cleanup_vm_comprehensive() {
  local vm_name="$1"
  local success=true
  
  log_info "cleanup" "[$vm_name] Starting comprehensive cleanup..."
  
  # 1. Get VM info before deletion
  local vm_info=""
  if az vm show -g "$rg" -n "$vm_name" >/dev/null 2>&1; then
    vm_info=$(az vm show -g "$rg" -n "$vm_name" -o json 2>/dev/null || echo "{}")
  fi
  
  # 2. Collect associated resource IDs
  local nic_ids=() disk_ids=() ip_ids=() nsg_ids=()
  
  if [ "$vm_info" != "{}" ]; then
    # Get NICs
    mapfile -t nic_ids < <(echo "$vm_info" | jq -r '.networkProfile.networkInterfaces[]?.id // empty' 2>/dev/null || true)
    
    # Get OS disk
    local os_disk_id
    os_disk_id=$(echo "$vm_info" | jq -r '.storageProfile.osDisk.managedDisk.id // empty' 2>/dev/null || true)
    [ -n "$os_disk_id" ] && disk_ids+=("$os_disk_id")
    
    # Get data disks
    mapfile -t data_disk_ids < <(echo "$vm_info" | jq -r '.storageProfile.dataDisks[]?.managedDisk.id // empty' 2>/dev/null || true)
    disk_ids+=("${data_disk_ids[@]}")
  fi
  
  # Find associated Public IPs and NSGs by name pattern
  mapfile -t ip_ids < <(az network public-ip list -g "$rg" --query "[?contains(name, '$vm_name')].id" -o tsv 2>/dev/null || true)
  mapfile -t nsg_ids < <(az network nsg list -g "$rg" --query "[?contains(name, '$vm_name')].id" -o tsv 2>/dev/null || true)
  
  # 3. Delete VM first
  if [ "$vm_info" != "{}" ]; then
    log_info "cleanup" "[$vm_name] Deleting VM..."
    if timeout 300 az vm delete -g "$rg" -n "$vm_name" --yes >/dev/null 2>&1; then
      log_info "cleanup" "[$vm_name] VM deleted successfully"
      mark_resource_deleted "$(echo "$vm_info" | jq -r '.id')"
    else
      log_error "cleanup" "[$vm_name] Failed to delete VM"
      success=false
    fi
  else
    log_warn "cleanup" "[$vm_name] VM not found, cleaning associated resources..."
  fi
  
  # 4. Delete NICs
  for nic_id in "${nic_ids[@]}"; do
    [ -z "$nic_id" ] && continue
    local nic_name; nic_name=$(basename "$nic_id")
    log_info "cleanup" "[$vm_name] Deleting NIC: $nic_name"
    
    if timeout 120 az network nic delete --ids "$nic_id" >/dev/null 2>&1; then
      log_info "cleanup" "[$vm_name] NIC $nic_name deleted"
      mark_resource_deleted "$nic_id"
    else
      log_error "cleanup" "[$vm_name] Failed to delete NIC $nic_name"
      success=false
    fi
  done
  
  # 5. Delete Public IPs
  for ip_id in "${ip_ids[@]}"; do
    [ -z "$ip_id" ] && continue
    local ip_name; ip_name=$(basename "$ip_id")
    log_info "cleanup" "[$vm_name] Deleting Public IP: $ip_name"
    
    if timeout 60 az network public-ip delete --ids "$ip_id" >/dev/null 2>&1; then
      log_info "cleanup" "[$vm_name] Public IP $ip_name deleted"
      mark_resource_deleted "$ip_id"
    else
      log_error "cleanup" "[$vm_name] Failed to delete Public IP $ip_name"
      success=false
    fi
  done
  
  # 6. Delete NSGs
  for nsg_id in "${nsg_ids[@]}"; do
    [ -z "$nsg_id" ] && continue
    local nsg_name; nsg_name=$(basename "$nsg_id")
    log_info "cleanup" "[$vm_name] Deleting NSG: $nsg_name"
    
    if timeout 60 az network nsg delete --ids "$nsg_id" >/dev/null 2>&1; then
      log_info "cleanup" "[$vm_name] NSG $nsg_name deleted"
      mark_resource_deleted "$nsg_id"
    else
      log_error "cleanup" "[$vm_name] Failed to delete NSG $nsg_name"
      success=false
    fi
  done
  
  # 7. Delete Disks (last, after VM is gone)
  for disk_id in "${disk_ids[@]}"; do
    [ -z "$disk_id" ] && continue
    local disk_name; disk_name=$(basename "$disk_id")
    log_info "cleanup" "[$vm_name] Deleting Disk: $disk_name"
    
    if timeout 120 az disk delete --ids "$disk_id" --yes >/dev/null 2>&1; then
      log_info "cleanup" "[$vm_name] Disk $disk_name deleted"
      mark_resource_deleted "$disk_id"
    else
      log_error "cleanup" "[$vm_name] Failed to delete Disk $disk_name"
      success=false
    fi
  done
  
  if $success; then
    log_info "cleanup" "[$vm_name] Comprehensive cleanup completed successfully"
  else
    log_warn "cleanup" "[$vm_name] Comprehensive cleanup completed with some failures"
  fi
  
  return $([ "$success" = true ] && echo 0 || echo 1)
}

# Función para limpiar recursos huérfanos
cleanup_orphaned_test_resources() {
  log_info "cleanup" "Searching for orphaned test resources..."
  
  # Find resources with test naming patterns that don't have VMs
  local orphaned_count=0
  
  # Orphaned NICs
  mapfile -t orphaned_nics < <(az network nic list -g "$rg" --query "[?starts_with(name, 't-') && !virtualMachine].name" -o tsv 2>/dev/null || true)
  for nic in "${orphaned_nics[@]}"; do
    [ -z "$nic" ] && continue
    log_info "cleanup" "Deleting orphaned NIC: $nic"
    if az network nic delete -g "$rg" -n "$nic" >/dev/null 2>&1; then
      ((orphaned_count++))
    fi
  done
  
  # Orphaned Public IPs
  mapfile -t orphaned_ips < <(az network public-ip list -g "$rg" --query "[?starts_with(name, 't-') && !ipConfiguration].name" -o tsv 2>/dev/null || true)
  for ip in "${orphaned_ips[@]}"; do
    [ -z "$ip" ] && continue
    log_info "cleanup" "Deleting orphaned Public IP: $ip"
    if az network public-ip delete -g "$rg" -n "$ip" >/dev/null 2>&1; then
      ((orphaned_count++))
    fi
  done
  
  # Orphaned NSGs
  mapfile -t orphaned_nsgs < <(az network nsg list -g "$rg" --query "[?starts_with(name, 't-') && length(networkInterfaces) == \`0\`].name" -o tsv 2>/dev/null || true)
  for nsg in "${orphaned_nsgs[@]}"; do
    [ -z "$nsg" ] && continue
    log_info "cleanup" "Deleting orphaned NSG: $nsg"
    if az network nsg delete -g "$rg" -n "$nsg" >/dev/null 2>&1; then
      ((orphaned_count++))
    fi
  done
  
  # Orphaned Disks
  mapfile -t orphaned_disks < <(az disk list -g "$rg" --query "[?starts_with(name, 't-') && diskState == 'Unattached'].name" -o tsv 2>/dev/null || true)
  for disk in "${orphaned_disks[@]}"; do
    [ -z "$disk" ] && continue
    log_info "cleanup" "Deleting orphaned Disk: $disk"
    if az disk delete -g "$rg" -n "$disk" --yes >/dev/null 2>&1; then
      ((orphaned_count++))
    fi
  done
  
  if [ $orphaned_count -gt 0 ]; then
    log_info "cleanup" "Cleaned up $orphaned_count orphaned resources"
  else
    log_info "cleanup" "No orphaned resources found"
  fi
}

# Enhanced cleanup_created_vms function
cleanup_created_vms() {
  if [ ! -s "$CREATED_VMS_FILE" ] && [ ! -f "$CREATED_RESOURCES_FILE" ]; then
    log_info "cleanup" "No VMs or resources to cleanup"
    return 0
  fi
  
  log_info "cleanup" "Starting comprehensive cleanup of created resources..."
  local cleanup_start; cleanup_start=$(date +%s)
  local total_vms; total_vms=$(wc -l < "$CREATED_VMS_FILE" 2>/dev/null || echo 0)
  local cleaned=0
  local failed_cleanups=()

  # Cleanup VMs and their resources
  if [ -s "$CREATED_VMS_FILE" ]; then
    while IFS= read -r vm_name; do
      [ -z "$vm_name" ] && continue
      ((cleaned++))
      
      log_info "cleanup" "[$cleaned/$total_vms] Processing VM: $vm_name"
      
      if ! cleanup_vm_comprehensive "$vm_name"; then
        failed_cleanups+=("$vm_name")
        log_warn "cleanup" "Failed to fully cleanup VM: $vm_name"
      fi
    done < "$CREATED_VMS_FILE"
  fi

  # Cleanup any remaining orphaned resources
  cleanup_orphaned_test_resources

  # Report results
  local cleanup_duration; cleanup_duration=$(( $(date +%s) - cleanup_start ))
  local failed_count=${#failed_cleanups[@]}
  
  if [ $failed_count -eq 0 ]; then
    log_info "cleanup" "Cleanup completed successfully in ${cleanup_duration}s for $cleaned VMs"
  else
    log_warn "cleanup" "Cleanup completed in ${cleanup_duration}s. $failed_count VMs had partial failures:"
    printf '%s\n' "${failed_cleanups[@]}" | sed 's/^/  - /'
  fi
  
  # Mark cleanup completion
  if [ -f "$CREATED_RESOURCES_FILE" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) Cleanup completed" >> artifacts/_cleanup.log
  fi
}

# Bootstrap
if [ "$DRY_RUN" -eq 0 ]; then
  if [ -f "$SCRIPT_DIR/lib/bootstrap.sh" ]; then
    # shellcheck source=lib/bootstrap.sh
    source "$SCRIPT_DIR/lib/bootstrap.sh"
    bootstrap_all "$SSH_PUB_DEFAULT" "$SSH_PRIV_DEFAULT"
  else
    log_error "main" "Bootstrap library not found: $SCRIPT_DIR/lib/bootstrap.sh"
    exit 66
  fi
else
  log_info "main" "Skipping Azure bootstrap in dry-run mode"
fi

# Read config
rg=$(jq -r '.resource_group' "$CONFIG")
vm_name_pattern=$(jq -r '.vm_name_pattern // "t-{series}-{type}-{size}"' "$CONFIG")
[ -n "$rg" ] || { log_error "main" "'resource_group' missing"; exit 65; }

if [ "$DRY_RUN" -eq 0 ]; then
  LOCATION=$(az group show --name "$rg" --query "location" -o tsv 2>/dev/null || true)
  [ -n "$LOCATION" ] || { log_error "main" "Resource group '$rg' does not exist or is not accessible"; exit 65; }
  log_info "main" "Resource group: $rg (location: $LOCATION)"
else
  LOCATION="eastus"  # Default para dry-run
  log_info "main" "Resource group: $rg (location: $LOCATION - dry-run)"
fi

# Read arrays in a compatible way
declare -a SERIES TYPES SIZES
while IFS= read -r line; do
  SERIES+=("$line")
done < <(jq -r '.matrix.series[]' "$CONFIG")

while IFS= read -r line; do
  TYPES+=("$line") 
done < <(jq -r '.matrix.types[]' "$CONFIG")

while IFS= read -r line; do
  SIZES+=("$line")
done < <(jq -r '.matrix.sizes[]' "$CONFIG")

tests_count=$(jq '.tests | length' "$CONFIG")

# Logs
mkdir -p artifacts
SKIP_LOG="artifacts/_skip_summary.log"
RESULTS_LOG="artifacts/_results_summary.log"
CREATED_VMS_FILE="artifacts/_created_vms.list"
: > "$SKIP_LOG"; : > "$RESULTS_LOG"; : > "$CREATED_VMS_FILE"

# Load library functions after we have the basic setup
if [ -f "$SCRIPT_DIR/lib/vm_test_lib.sh" ]; then
  # shellcheck source=lib/vm_test_lib.sh
  source "$SCRIPT_DIR/lib/vm_test_lib.sh"
else
  log_error "main" "VM test library not found: $SCRIPT_DIR/lib/vm_test_lib.sh"
  exit 66
fi

# Worklist
declare -a WORKLIST=()
build_worklist "$SERIES_FILTER" "$rg" "$LOCATION" WORKLIST

if [ "${#WORKLIST[@]}" -eq 0 ]; then
  log_warn "main" "No matching combinations after filtering"
  # Create empty results files
  : > "$RESULTS_LOG"
  : > "$SKIP_LOG"
  print_final_summary "$RESULTS_LOG" "$SKIP_LOG"
  if [ "$ENABLE_JSON_SUMMARY" -eq 1 ]; then
    if [ -f "$SCRIPT_DIR/lib/json_summary.sh" ]; then
      # shellcheck source=lib/json_summary.sh
      source "$SCRIPT_DIR/lib/json_summary.sh"
      mkdir -p "$(dirname "$JSON_OUT")"
      write_summary_json "$JSON_OUT" "$RESULTS_LOG" "$SKIP_LOG" "$rg" "$LOCATION" "$SERIES_FILTER" "$MAX_PARALLEL"
      log_info "main" "Saved JSON summary to: $JSON_OUT"
    fi
  fi
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "===== DRY RUN SUMMARY ====="
  echo "Would create ${#WORKLIST[@]} VMs with the following configurations:"
  echo ""
  for tuple in "${WORKLIST[@]}"; do
    IFS='|' read -r series type size offer sku vm_name <<<"$tuple"
    echo "  $vm_name: $series/$type/$size ($offer:$sku)"
  done
  echo ""
  echo "Use --json to see detailed breakdown, or remove --dry-run to execute."
  
  if [ "$ENABLE_JSON_SUMMARY" -eq 1 ]; then
    # Crear un summary JSON básico para dry-run
    jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg rg "$rg" --arg loc "$LOCATION" \
          --argjson total "${#WORKLIST[@]}" \
          --arg mode "dry_run" \
          '{
            _comments: "Dry run summary",
            run: {timestamp: $ts, resource_group: $rg, location: $loc, mode: $mode},
            totals: {total_planned: $total, executed: 0},
            planned_vms: []
          }' > "$JSON_OUT"
    
    # Agregar VMs planeadas
    tmp_planned="$(mktemp)"
    for tuple in "${WORKLIST[@]}"; do
      IFS='|' read -r series type size offer sku vm_name <<<"$tuple"
      jq -n --arg vm "$vm_name" --arg series "$series" --arg type "$type" \
            --arg size "$size" --arg offer "$offer" --arg sku "$sku" \
            '{vm: $vm, series: $series, type: $type, size: $size, offer: $offer, sku: $sku}'
    done | jq -s '.' > "$tmp_planned"
    
    jq --slurpfile planned "$tmp_planned" '.planned_vms = $planned[0]' "$JSON_OUT" > "$JSON_OUT.tmp" && mv "$JSON_OUT.tmp" "$JSON_OUT"
    rm -f "$tmp_planned"
    
    log_info "main" "Saved dry-run summary to: $JSON_OUT"
  fi
  
  exit 0
fi

# Apply timeout multiplier
if [ "$TIMEOUT_MULTIPLIER" != "1.0" ]; then
  SSH_RETRIES=$(awk "BEGIN {printf \"%.0f\", $SSH_RETRIES * $TIMEOUT_MULTIPLIER}")
  VM_POWER_RETRIES=$(awk "BEGIN {printf \"%.0f\", ${VM_POWER_RETRIES:-60} * $TIMEOUT_MULTIPLIER}")
  log_info "main" "Applied timeout multiplier $TIMEOUT_MULTIPLIER: SSH_RETRIES=$SSH_RETRIES, VM_POWER_RETRIES=$VM_POWER_RETRIES"
fi

export PUBLISHER VERSION ADMIN_USER SSH_PUB_DEFAULT SSH_PRIV_DEFAULT rg LOCATION CONFIG CREATED_VMS_FILE ARCH_FILTER TYPE_FILTER SIZE_FILTER CLEANUP_NETWORK \
       SSH_CONNECT_TIMEOUT SSH_RETRIES SSH_SLEEP vm_name_pattern SKIP_LOG RESULTS_LOG SERIES_FILTER MAX_PARALLEL CORRELATION_ID TIMEOUT_MULTIPLIER \
       CREATED_RESOURCES_FILE

# Export functions from vm_test_lib for use in subshells
export -f run_combo log warn err catalog_lookup slugify label_for arch_for wait_vm_running \
          metrics_from_file collect_metrics_for_vm evaluate_policies validate_combination \
          vm_exists wait_ssh restart_vm run_remote run_remote_with_retry \
          append_skip append_result configure_adaptive_timeouts detect_network_issues \
          is_safe_to_delete_network cleanup_subnet_safely safe_network_cleanup \
          register_resource mark_resource_deleted get_vm_resources cleanup_vm_comprehensive 2>/dev/null || true

# Simple functions for job management
active_jobs() { 
  local count
  count=$(jobs 2>/dev/null | grep -c "Running" 2>/dev/null || echo 0)
  # Ensure we return a clean number
  echo "$count" | tr -d '\n\r'
}

monitor_progress() {
  local total_jobs="$1"
  local start_time; start_time=$(date +%s)
  
  while true; do
    local running; running=$(active_jobs)
    if [ "$running" -eq 0 ]; then
      break
    fi
    
    local completed; completed=$(( total_jobs - running ))
    local elapsed; elapsed=$(( $(date +%s) - start_time ))
    local rate; rate=$(awk "BEGIN {if ($elapsed > 0) printf \"%.2f\", $completed / $elapsed * 60; else print \"0.00\"}")
    
    printf "\r[%s] Progress: %d/%d completed, %d running, %.2f jobs/min, %ds elapsed" \
           "$(date '+%H:%M:%S')" "$completed" "$total_jobs" "$running" "$rate" "$elapsed"
    sleep 5
  done
  printf "\n"
}

# Enhanced cleanup_on_exit function
cleanup_on_exit() {
  local exit_code=$?
  log_info "main" "Exit handler triggered (exit_code: $exit_code)"
  
  # Terminar trabajos en segundo plano
  local running_jobs
  running_jobs=$(jobs -p 2>/dev/null | wc -l || echo 0)
  
  if [ "$running_jobs" -gt 0 ]; then
    log_info "main" "Terminating $running_jobs background jobs..."
    # Kill all background jobs
    jobs -p | xargs -r kill 2>/dev/null || true
    sleep 3
    # Force kill if still running
    jobs -p | xargs -r kill -9 2>/dev/null || true
  fi
  
  # Cleanup VMs unless KEEP_VMs is set
  if [ "$KEEP_VMS" -eq 0 ]; then
    cleanup_created_vms
  else
    log_warn "main" "Skipping cleanup due to --keep-vms flag"
    if [ -s "$CREATED_VMS_FILE" ]; then
      log_info "main" "VMs that were NOT cleaned up:"
      cat "$CREATED_VMS_FILE" | sed 's/^/  - /'
    fi
  fi
  
  exit $exit_code
}

trap cleanup_on_exit EXIT INT TERM

log_info "main" "Starting parallel execution with max-parallel=$MAX_PARALLEL"
start_time=$(date +%s)

# Ejecutar trabajos en paralelo
for tuple in "${WORKLIST[@]}"; do
  IFS='|' read -r series type size offer sku vm_name <<<"$tuple"
  
  # Wait for available slot
  running_jobs=""
  while true; do
    running_jobs=$(active_jobs)
    if [ "$running_jobs" -lt "$MAX_PARALLEL" ]; then
      break
    fi
    sleep 1
  done
  
  log_info "scheduler" "Starting job for $vm_name ($series/$type/$size)"
  bash -c "run_combo \"$series\" \"$type\" \"$size\" \"$offer\" \"$sku\" \"$vm_name\"" &
done

# Monitorear progreso
if [ "${#WORKLIST[@]}" -gt 1 ]; then
  monitor_progress "${#WORKLIST[@]}" &
  MONITOR_PID=$!
fi

# Esperar a que terminen todos los trabajos
wait

# Terminar monitor si está corriendo
if [ -n "${MONITOR_PID:-}" ]; then
  kill "$MONITOR_PID" 2>/dev/null || true
fi

execution_duration=$(( $(date +%s) - start_time ))
log_info "main" "All jobs completed in ${execution_duration}s"

# Summary
print_final_summary "$RESULTS_LOG" "$SKIP_LOG"

# JSON
if [ "$ENABLE_JSON_SUMMARY" -eq 1 ]; then
  log_info "main" "Generating JSON summary..."
  if [ -f "$SCRIPT_DIR/lib/json_summary.sh" ]; then
    # shellcheck source=lib/json_summary.sh
    source "$SCRIPT_DIR/lib/json_summary.sh"
    mkdir -p "$(dirname "$JSON_OUT")"
    write_summary_json "$JSON_OUT" "$RESULTS_LOG" "$SKIP_LOG" "$rg" "$LOCATION" "$SERIES_FILTER" "$MAX_PARALLEL"
    log_info "main" "Saved JSON summary to: $JSON_OUT"
    
    # Mostrar estadísticas clave del JSON
    if command -v jq >/dev/null 2>&1; then
      echo ""
      echo "===== KEY STATISTICS ====="
      jq -r '
        "Success Rate: \(.totals.success_rate // 0)%",
        "Total VMs: \(.performance_stats.total_vms // 0)",
        "Critical Skips: \(.summary_stats.critical_skips // 0)",
        "Policy Failures: \(.summary_stats.policy_failures // 0)",
        "Completion Rate: \(.performance_stats.completion_rate // 0)%"
      ' "$JSON_OUT" 2>/dev/null | while read -r line; do
        echo "  $line"
      done || echo "  (JSON statistics not available)"
      echo "=========================="
    fi
  fi
fi

# Cleanup VMs unless KEEP_VMs
if [ "$KEEP_VMS" -eq 0 ]; then
  # Final cleanup happens in cleanup_on_exit
  : # No-op, cleanup handled by trap
else
  log_warn "main" "Skipping cleanup due to --keep-vms"
fi

# Exit code for CI
BAD_CNT=0
CRITICAL_SKIPS=0

if [ -f "$RESULTS_LOG" ]; then
  BAD_CNT=$(grep -c '^BAD|' "$RESULTS_LOG" 2>/dev/null || echo 0)
fi

if [ -f "$SKIP_LOG" ]; then
  # Count each critical skip type separately and sum them
  SKIP_CREATE=$(grep -c '^RUN:CREATE' "$SKIP_LOG" 2>/dev/null || echo 0)
  SKIP_CREATE_POWER=$(grep -c '^RUN:CREATE_POWER' "$SKIP_LOG" 2>/dev/null || echo 0)
  SKIP_IP=$(grep -c '^RUN:IP' "$SKIP_LOG" 2>/dev/null || echo 0)
  SKIP_SSH=$(grep -c '^RUN:SSH' "$SKIP_LOG" 2>/dev/null || echo 0)
  SKIP_SSH_LOST=$(grep -c '^RUN:SSH_LOST' "$SKIP_LOG" 2>/dev/null || echo 0)
  SKIP_REBOOT_SSH=$(grep -c '^RUN:REBOOT_SSH' "$SKIP_LOG" 2>/dev/null || echo 0)
  CRITICAL_SKIPS=$((SKIP_CREATE + SKIP_CREATE_POWER + SKIP_IP + SKIP_SSH + SKIP_SSH_LOST + SKIP_REBOOT_SSH))
fi

if [ "$BAD_CNT" -gt 0 ]; then
  log_error "main" "There are $BAD_CNT BAD tests. Failing with exit code 1"
  exit 1
elif [ "$CRITICAL_SKIPS" -gt 5 ]; then
  log_warn "main" "High number of critical skips ($CRITICAL_SKIPS). Might indicate infrastructure issues"
  exit 2
fi

log_info "main" "Matrix run finished successfully. See ./artifacts/"
exit 0