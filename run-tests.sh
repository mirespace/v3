#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/vm_test_lib.sh
source "$SCRIPT_DIR/lib/vm_test_lib.sh"
# shellcheck source=lib/bootstrap.sh
source "$SCRIPT_DIR/lib/bootstrap.sh"
# shellcheck source=lib/json_summary.sh
source "$SCRIPT_DIR/lib/json_summary.sh"

# --- Stubs defensivos por si fallan los source (evita que las traps mueran) ---
if ! declare -F cleanup_created_vms >/dev/null 2>&1; then
  cleanup_created_vms() { :; }
fi
if ! declare -F log >/dev/null 2>&1; then
  log()  { echo "[INFO] $*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { echo "[WARN] $*"; }
fi
if ! declare -F err >/dev/null 2>&1; then
  err()  { echo "[ERROR] $*" >&2; }
fi

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

# ------------------------- Defaults -------------------------
PUBLISHER="${PUBLISHER:-Canonical}"
VERSION="${VERSION:-latest}"
ADMIN_USER="${ADMIN_USER:-ubuntu}"
SSH_PUB_DEFAULT="${SSH_PUB_DEFAULT:-$HOME/.ssh/id_rsa.pub}"
SSH_PRIV_DEFAULT="${SSH_PRIV_DEFAULT:-${SSH_PUB_DEFAULT%.pub}}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-6}"
SSH_RETRIES="${SSH_RETRIES:-40}"
SSH_SLEEP="${SSH_SLEEP:-5}"

# ------------------------- Test configuration json file -----

if [[ "${1-}" == "-h" || "${1-}" == "--help" ]]; then print_help; exit 0; fi
CONFIG="${1-}"; shift 1 || true
[ -f "${CONFIG:-}" ] || { err "Config file not found: ${CONFIG:-<missing>}"; exit 64; }


# ------------------------- Flags ----------------------------
SERIES_FILTER="all"
MAX_PARALLEL=1
ENABLE_JSON_SUMMARY=0
ARTIFACTS_DIR="artifacts"
JSON_OUT="${ARTIFACTS_DIR}/summary.json"
ARCH_FILTER="all"
TYPE_FILTER="all"
SIZE_FILTER="all"
CLEANUP_NETWORK=0
KEEP_VMS=0
HELP_FLAG=0
# Flags de control para evitar duplicados
SUMMARY_PRINTED=0
JSON_WRITTEN=0

# ------------------------- Parse args -----------------------
while (( "$#" )); do
  case "$1" in
    --series)       SERIES_FILTER="${2-}"; shift 2 ;;
    --max-parallel) MAX_PARALLEL="${2-}"; shift 2 ;;
    --arch)         ARCH_FILTER="${2-}";  shift 2 ;;
    --type)         TYPE_FILTER="${2-}";  shift 2 ;;
    --size)         SIZE_FILTER="${2-}";  shift 2 ;;
    --keep-vms)     KEEP_VMS=1;            shift 1 ;;
    --cleanup-network) CLEANUP_NETWORK=1;  shift 1 ;;
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

# --------------------- Contextual help ----------------------
if [ "$HELP_FLAG" -eq 1 ]; then
  if [ -f "${CONFIG:-}" ]; then print_help "$CONFIG"; else print_help; fi
  exit 0
fi

# ---------------- Infer ARCH from TYPE ----------------------
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

# ================== Artifacts scoping =======================
init_artifacts_scope() {
  export RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
  export ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
  mkdir -p "${ARTIFACTS_DIR}/history"
  for f in _results_summary.log _skip_summary.log _final_summary.log _bad_policy.log _bad_cmd.log ; do
    if [[ -f "${ARTIFACTS_DIR}/${f}" ]]; then
      mv -f "${ARTIFACTS_DIR}/${f}" "${ARTIFACTS_DIR}/history/${f%.log}-${RUN_ID}.log"
    fi
    : > "${ARTIFACTS_DIR}/${f}"
  done
}
init_artifacts_scope

# ---- Cabecera de contexto de ejecución ----
log "==== RUN CONTEXT ===="
log "Run ID:        ${RUN_ID}"
log "Test matrix:   ${CONFIG}"
log "Series filter: ${SERIES_FILTER:-ALL}"
log "Type filter:   ${TYPE_FILTER:-ALL}"
log "Arch filter:   ${ARCH_FILTER:-AUTO}"
log "Size filter:   ${SIZE_FILTER:-ALL}"
log "====================="

# ------------------------ Bootstrap -------------------------
bootstrap_all "$SSH_PUB_DEFAULT" "$SSH_PRIV_DEFAULT"

# ------------------------ Read config -----------------------
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

# -------------------------- Logs ----------------------------
mkdir -p "$ARTIFACTS_DIR"
BAD_POLICY_LOG="${ARTIFACTS_DIR}/_bad_policy.log"
BAD_CMD_LOG="${ARTIFACTS_DIR}/_bad_cmd.log"
SKIP_LOG="${ARTIFACTS_DIR}/_skip_summary.log"
RESULTS_LOG="${ARTIFACTS_DIR}/_results_summary.log"
FINAL_SUMMARY_LOG="${ARTIFACTS_DIR}/_final_summary.log"
CREATED_VMS_FILE="${ARTIFACTS_DIR}/_created_vms.list"
: > "$BAD_POLICY_LOG"; : > "$BAD_CMD_LOG"; : > "$SKIP_LOG"; : > "$RESULTS_LOG"; : > "$FINAL_SUMMARY_LOG"; : > "$CREATED_VMS_FILE"

export ARTIFACTS_DIR BAD_POLICY_LOG BAD_CMD_LOG RESULTS_LOG SKIP_LOG CREATED_VMS_FILE FINAL_SUMMARY_LOG
export rg LOCATION CONFIG SERIES_FILTER MAX_PARALLEL ARCH_FILTER TYPE_FILTER SIZE_FILTER CLEANUP_NETWORK KEEP_VMS

# ---------------------- Helper funcs ------------------------
active_jobs() { jobs -rp | wc -l | tr -d ' '; }

# ---------------------- Pre-run leftover sweep ---------------------------
# Borra VMs de ejecuciones anteriores que matchean la WORKLIST actual
# (mismos series/type/size => mismo vm_name) y que NO están en _created_vms.list
pre_run_cleanup_leftovers() {
  local rg="$1" live_file="$2"; shift 2
  local -n _worklist_ref="$1"

  # Si el usuario ha pedido conservar VMs, no barrer leftovers
  if [ "${KEEP_VMS:-0}" -eq 1 ]; then
    warn "[pre] --keep-vms activo: no se limpiarán VMs previas."
    return 0
  fi

  local tmp_left="${ARTIFACTS_DIR}/_leftovers_pre.list"
  : > "$tmp_left"

  log "[pre] Searching for leftover VMs from previous runs that match the current matrix…"
  for tuple in "${_worklist_ref[@]}"; do
    IFS='|' read -r series type size offer sku vm_name <<<"$tuple"

    # Existe la VM en Azure pero no es de esta ejecución (no está registrada en _created_vms.list)
    if az vm show -g "$rg" -n "$vm_name" >/dev/null 2>&1; then
      if ! grep -qx "$vm_name" "$live_file" 2>/dev/null; then
        echo "$vm_name" >> "$tmp_left"
      fi
    fi
  done

  if [ -s "$tmp_left" ]; then
    local n
    n=$(wc -l < "$tmp_left" | tr -d ' ')
    warn "[pre] Detected ${n} leftover VM(s) from previous runs for this matrix. Starting cleanup…"

    # Reutilizamos tu limpiador cambiando temporalmente el CREATED_VMS_FILE
    local _saved_list="$CREATED_VMS_FILE"
    CREATED_VMS_FILE="$tmp_left"
    cleanup_created_vms || warn "[pre] Cleanup de leftovers con incidencias (revisa logs)"
    CREATED_VMS_FILE="$_saved_list"
  else
    log "[pre] No leftovers found for the current matrix."
  fi
}


# ------------------ Cleanup Function ----------------------------------
# Definir la función de limpieza una sola vez
cleanup_function() {
  local exit_code=${1:-$?}
  log "[cleanup] Starting cleanup process (exit_code=$exit_code)..."
  
  # Generar JSON si está habilitado y no se ha escrito todavía
  if [ "$ENABLE_JSON_SUMMARY" -eq 1 ] && [ $JSON_WRITTEN -eq 0 ]; then
    mkdir -p "$(dirname "$JSON_OUT")"
    if write_summary_json "$JSON_OUT" "$RESULTS_LOG" "$SKIP_LOG" \
                         "$rg" "$LOCATION" "$SERIES_FILTER" "$MAX_PARALLEL" "$CREATED_VMS_FILE"; then
      log "[cleanup] Saved JSON summary to: $JSON_OUT"
      JSON_WRITTEN=1
      # Mostrar KEY STATISTICS inmediatamente tras escribir el JSON
      if [ -f "$JSON_OUT" ]; then
        print_key_statistics "$JSON_OUT" | tee -a "$FINAL_SUMMARY_LOG"  || true
      fi
    else
      warn "[cleanup] Failed to write JSON summary"
    fi
  fi
  

  # Clasificar BAD por tipo
  awk -F'|' '
    /^BAD\|/ {
      if ($0 ~ /\[POLICY\]/) {
        print $0 >> ENVIRON["BAD_POLICY_LOG"]
      } else {
        print $0 >> ENVIRON["BAD_CMD_LOG"]
      }
    }
  ' "$RESULTS_LOG" 2>/dev/null || true

  # Imprimir summary unificado
  if [ $SUMMARY_PRINTED -eq 0 ]; then
    {
      # Summary básico (GOOD/BAD/SKIP)
      if declare -f print_final_summary >/dev/null 2>&1; then
        print_final_summary "$RESULTS_LOG" "$SKIP_LOG" || true
      fi

      # Summary extendido mejorado (o el antiguo si no existe el nuevo)
      if declare -f print_enhanced_final_summary >/dev/null 2>&1; then
        print_enhanced_final_summary "${ARTIFACTS_DIR:-artifacts}" "$CONFIG" || true
      elif declare -f print_final_summary_ext >/dev/null 2>&1; then
        print_final_summary_ext "${ARTIFACTS_DIR:-artifacts}" "$CONFIG" || true
      fi
    } | tee -a "$FINAL_SUMMARY_LOG"
    SUMMARY_PRINTED=1
  fi

  # Limpieza de VMs
  if [ "${KEEP_VMS:-0}" -eq 0 ] && [ -s "$CREATED_VMS_FILE" ]; then
    log "[cleanup] Cleaning up created VMs..."
    cleanup_created_vms || warn "[cleanup] VM cleanup had issues"
  elif [ "${KEEP_VMS:-0}" -eq 1 ]; then
    warn "[cleanup] Skipping VM cleanup due to --keep-vms flag"
  fi
  
  log "[cleanup] Cleanup process completed"
  # Importante: desactivar traps para evitar loops infinitos
  trap - EXIT INT TERM
}

# ------------------ Key Statistics Function ----------------------------------
print_key_statistics() {
  local json_file="$1"
  if [ -f "$json_file" ] && command -v jq >/dev/null 2>&1; then
    echo ""
    jq -r '
      def nz: . // 0;
      def pct(n;d): if d==0 then 0 else ((n*100.0)/d + 0.5|floor) end;
      . as $r |
      ($r.totals.GOOD|nz) as $g | 
      ($r.totals.BAD|nz) as $b |
      ($r.details.good + $r.details.bad | map(.vm) | unique | length) as $vms |
      (pct($g; ($g+$b))) as $succ_rate |
      "===== KEY STATISTICS =====\n  Success Rate: \($succ_rate)%\n  Total VMs: \($vms)\n  Good Tests: \($g)\n  Bad Tests: \($b)\n=========================="' "$json_file" 2>/dev/null || {
        echo "===== KEY STATISTICS ====="
        echo "  (Unable to parse statistics)"
        echo "=========================="
      }
  else
    echo "===== KEY STATISTICS ====="
    echo "  (Statistics not available)"
    echo "=========================="
  fi
}


# ------------------ Enhanced Final Summary Function ----------------------------------
# Esta función reemplaza o complementa print_final_summary_ext()
print_enhanced_final_summary() {
  local artifacts_dir="$1"
  local config="$2"
  local results_log="${artifacts_dir}/_results_summary.log"
  local skip_log="${artifacts_dir}/_skip_summary.log"
  local json_file="${artifacts_dir}/summary.json"
  
  # Detectar número de tests esperados por VM desde el config o estimar
  local expected_tests_per_vm=3  # Default: prechecks, install-reboot, postchecks
  if [ -f "$config" ] && command -v jq >/dev/null 2>&1; then
    expected_tests_per_vm=$(jq '.tests | length' "$config" 2>/dev/null || echo 3)
  fi
  
  echo "==== FINAL SUMMARY (EXTENDED) ===="
  
  # Procesar estadísticas en una sola pasada con awk
  local stats_output=$(awk -F'|' '
    BEGIN {
      good_count = 0; bad_count = 0; skip_count = 0;
      total_tests = 0; unique_vms = 0; successful_vms = 0;
    }
    
    # Procesar results_log
    FNR == NR && /^GOOD\|/ {
      good_count++;
      vms[$2]++;
      good_per_vm[$2]++;
    }
    
    FNR == NR && /^BAD\|/ {
      bad_count++;
      vms[$2]++;
    }
    
    # Procesar skip_log  
    FNR != NR && /^SKIP\|/ {
      skip_count++;
    }
    
    END {
      total_tests = good_count + bad_count + skip_count;
      unique_vms = length(vms);
      
      # Contar VMs completamente exitosas (3 o más tests GOOD)
      for(vm in good_per_vm) {
        if(good_per_vm[vm] >= 3) successful_vms++;
      }
      
      # Calcular porcentajes
      test_success_rate = (total_tests > 0) ? int((good_count * 100) / total_tests) : 0;
      vm_success_rate = (unique_vms > 0) ? int((successful_vms * 100) / unique_vms) : 0;
      
      printf "STATS:%d:%d:%d:%d:%d:%d:%d:%d\n", 
        good_count, bad_count, skip_count, total_tests, 
        unique_vms, successful_vms, test_success_rate, vm_success_rate;
    }
  ' "$results_log" "$skip_log" 2>/dev/null || echo "STATS:0:0:0:0:0:0:0:0")
  
  # Parsear resultados
  local good_count=$(echo "$stats_output" | cut -d: -f2)
  local bad_count=$(echo "$stats_output" | cut -d: -f3)
  local bad_policy_count=$(awk -F'|' '/^BAD\|/ && /\[POLICY\]/ {c++} END{print c+0}' "$results_log" 2>/dev/null)
  local bad_cmd_count=$(awk -F'|' '/^BAD\|/ && !/\[POLICY\]/ {c++} END{print c+0}' "$results_log" 2>/dev/null)
  local skip_count=$(echo "$stats_output" | cut -d: -f4)
  local total_tests=$(echo "$stats_output" | cut -d: -f5)
  local unique_vms=$(echo "$stats_output" | cut -d: -f6)
  local successful_vms=$(echo "$stats_output" | cut -d: -f7)
  local test_success_rate=$(echo "$stats_output" | cut -d: -f8)
  local vm_success_rate=$(echo "$stats_output" | cut -d: -f9)
  
  # Información básica con estadísticas mejoradas
  printf "%-24s %d\n" "VMs with tests:" "$unique_vms"
  printf "%-24s %d / %d (%d%%)\n" "VMs all phases OK:" "$successful_vms" "$unique_vms" "$vm_success_rate"
  printf "%-24s %d / %d (%d%%)\n" "Test success rate:" "$good_count" "$total_tests" "$test_success_rate"
  
  # Breakdown de tests
  echo "-- Test Breakdown --"
  printf "  ✓ Passed: %d   ✗ Failed: %d   ⏭ Skipped: %d   📊 Total: %d\n" "$good_count" "$bad_count" "$skip_count" "$total_tests"
  printf "  • Failures breakdown → Policy: %d   Cmd/Runtime: %d\n" "$bad_policy_count" "$bad_cmd_count"

  # Series completadas (usando awk optimizado)
  local series_analysis=$(awk -F'|' -v n="${expected_tests_per_vm:-3}" '
  function kvgrab(key,   i,a){ for(i=1;i<=NF;i++) if($i ~ "^"key"="){split($i,a,"="); return a[2]} return "" }
  /^(GOOD|BAD)\|/ {
    v = kvgrab("vm"); s = kvgrab("series"); st=$1
    if (v==""||s=="") next
    vm_series[v]=s
    if (st=="GOOD") vm_good[v]++
    else if (st=="BAD") vm_bad[v]++
  }
  END{
    # por VM: éxito si no tiene BAD y tiene al menos n GOOD
    for (v in vm_series){
      s=vm_series[v]
      series_total_vms[s]++
      if ((v in vm_bad)==0 && vm_good[v] >= n) series_ok_vms[s]++
    }
    completed=""
    failed=""
    for (s in series_total_vms){
      if (s in series_ok_vms && series_ok_vms[s]==series_total_vms[s]) {
        completed = completed " " s
      } else {
        failed = failed s ":" (s in series_ok_vms ? series_ok_vms[s] : 0) "/" series_total_vms[s] " "
      }
    }
    printf "SERIES:%s:%s\n", completed, failed
  }' "$results_log" 2>/dev/null || echo "SERIES:: ")

  
  local completed_series=$(echo "$series_analysis" | cut -d: -f2)
  local failed_series=$(echo "$series_analysis" | cut -d: -f3)
  
  if [ -n "$completed_series" ]; then
    echo "Completed series:       $completed_series"
  else
    echo "Completed series:       (none)"
  fi
  
  # Fallos por series (usando awk optimizado)
  echo "-- Fails by series (VMs failed / VMs total) --"
  awk -F'|' '
    function kvgrab(key,   i,a) {
      for (i=1;i<=NF;i++) if ($i ~ "^" key "=") { split($i,a,"="); return a[2] }
      return ""
    }
    /^(GOOD|BAD)\|/ {
      s = kvgrab("series"); v = kvgrab("vm"); st = $1
      if (s=="" || v=="") next
      vm_series[v] = s
      vm_seen[v] = 1
      if (st=="BAD") vm_bad[v] = 1
    }
    END {
      for (v in vm_seen) {
        s = vm_series[v]
        series_vm_total[s]++
        if (v in vm_bad) series_vm_failed[s]++
      }
      for (s in series_vm_total) {
        f = (s in series_vm_failed) ? series_vm_failed[s] : 0
        printf "  %s: %d/%d\n", s, f, series_vm_total[s]
      }
    }
  ' "$results_log" 2>/dev/null
  
  # Políticas fallidas (usando awk optimizado)
  local policy_failures=$(awk -F'|' '
    /^BAD\|.*\[POLICY\]/ {
      match($0, /name=([^ ]*) /, arr); 
      policy=arr[1];
      match($0, /vm=([^|]*)\|/, arr);
      vm=arr[1];
      match($0, /size=([^|]*)\|/, arr);
      size=arr[1];
      
      policies[policy]++;
      if(details[policy] == "") {
        details[policy] = vm " (size=" size ")";
      } else {
        details[policy] = details[policy] "\n       - " vm " (size=" size ")";
      }
    } 
    END {
      if(length(policies) > 0) {
        print "-- Failed policies --";
        for(p in policies) {
          printf "  [%dx] %s\n", policies[p], p;
          printf "       - %s\n", details[p];
        }
      }
    }' "$results_log" 2>/dev/null)
  
  if [ -n "$policy_failures" ]; then
    echo "$policy_failures"
  fi
  
  # Command Runtime/Failueres
  if [ "$bad_cmd_count" -gt 0 ]; then
    echo "-- Command/Runtime failures --"
    awk -F'|' '
      /^BAD\|/ && !/\[POLICY\]/ {
        vm=""; test="";
        for(i=1;i<=NF;i++){
          if($i ~ /^vm=/){split($i,a,"="); vm=a[2]}
          if($i ~ /^test=/){split($i,a,"="); test=a[2]}
        }
        if(vm=="" || test==""){print "  - " $0}
        else {printf "  - %s (%s)\n", vm, test}
      }
    ' "$results_log" 2>/dev/null
    echo "  (Ver detalles en $BAD_CMD_LOG)"
  fi


  # Calcular progreso hacia 100% completo
  echo "-- Overall Status --"
  
  # Calcular el progreso real basado en VMs y tests esperados
  local expected_total_tests=$((unique_vms * expected_tests_per_vm))
  local completion_percentage=0
  
  if [ "$expected_total_tests" -gt 0 ]; then
    completion_percentage=$(( (good_count * 100) / expected_total_tests ))
  fi
  
  local missing_tests=$((expected_total_tests - good_count))
  local progress_to_100=$((100 - completion_percentage))
  
  # Análisis detallado del estado
  if [ "$bad_count" -eq 0 ] && [ "$skip_count" -eq 0 ] && [ "$completion_percentage" -eq 100 ]; then
    echo "  🎉 PERFECT RUN! All ${unique_vms} VMs completed successfully (100%)"
  elif [ "$bad_count" -eq 0 ] && [ "$completion_percentage" -eq 100 ]; then
    echo "  ✅ All VMs completed successfully! (${skip_count} tests were skipped)"
  elif [ "$completion_percentage" -ge 90 ]; then
    echo "  🟢 Excellent! ${completion_percentage}% complete - only ${progress_to_100}% remaining"
    echo "     Missing: ${missing_tests} successful tests to reach 100%"
  elif [ "$completion_percentage" -ge 75 ]; then
    echo "  🟡 Good progress! ${completion_percentage}% complete - ${progress_to_100}% remaining"
    echo "     Missing: ${missing_tests} successful tests to reach 100%"
  elif [ "$completion_percentage" -ge 50 ]; then
    echo "  🟠 Halfway there. ${completion_percentage}% complete - ${progress_to_100}% remaining"
    echo "     Missing: ${missing_tests} successful tests to reach 100%"
  elif [ "$completion_percentage" -ge 25 ]; then
    echo "  🔴 Early stage. ${completion_percentage}% complete - ${progress_to_100}% remaining"
    echo "     Missing: ${missing_tests} successful tests to reach 100%"
  else
    echo "  🔥 Just getting started. ${completion_percentage}% complete - ${progress_to_100}% remaining"
    echo "     Missing: ${missing_tests} successful tests to reach 100%"
  fi
  
  # Desglose específico de lo que falta
  if [ "$completion_percentage" -lt 100 ]; then
    echo "-- What's needed for 100% completion --"
    
    # VMs que necesitan trabajo
    local incomplete_vms=$((unique_vms - successful_vms))
    if [ "$incomplete_vms" -gt 0 ]; then
      echo "  • ${incomplete_vms} VM(s) need to complete all phases successfully"
    fi
    
    # Tests específicos que fallan
    if [ "$bad_count" -gt 0 ]; then
      echo "  • ${bad_count} failing test(s) need to be fixed"
      
      # Mostrar las VMs específicas que tienen fallos (usando awk)
      local failing_vms=$(awk -F'|' '/^BAD\|/{print $2}' "$results_log" | awk '!seen[$0]++{count++}END{print count+0}' 2>/dev/null || echo 0)
      if [ "$failing_vms" -gt 0 ]; then
        echo "  • ${failing_vms} VM(s) have at least one failing test"
      fi
    fi
    
    # Tests que faltan por ejecutar
    if [ "$skip_count" -gt 0 ]; then
      echo "  • ${skip_count} skipped test(s) need to be executed"
    fi
    
    # Estimación de esfuerzo
    if [ "$bad_count" -gt 0 ] || [ "$skip_count" -gt 0 ]; then
      local remediation_effort=""
      if [ "$bad_count" -gt 0 ] && [ "$skip_count" -gt 0 ]; then
        remediation_effort="Fix ${bad_count} failing tests and execute ${skip_count} skipped tests"
      elif [ "$bad_count" -gt 0 ]; then
        remediation_effort="Fix ${bad_count} failing test(s)"
      else
        remediation_effort="Execute ${skip_count} skipped test(s)"
      fi
      echo "  • Action needed: ${remediation_effort}"
    fi
  fi
  
  echo "===================================="
}

# ------------------ Enhanced VM Cleanup ----------------------------------
cleanup_created_vms() {
  if [ ! -s "$CREATED_VMS_FILE" ]; then
    log "No VMs to cleanup."
    return 0
  fi
  
  log "Starting cleanup of created VMs..."
  local cleanup_errors=0
  
  while IFS= read -r VM; do
    [ -z "$VM" ] && continue
    log "[$VM] Starting cleanup process..."
    
    # Verificar si la VM existe
    if ! az vm show -g "$rg" -n "$VM" >/dev/null 2>&1; then
      warn "[$VM] VM not found (maybe already deleted). Skipping."
      continue
    fi
    
    log "[$VM] Collecting attached resources for deletion..."
    VM_JSON=$(az vm show -g "$rg" -n "$VM" -d -o json 2>/dev/null || true)
    if [ -z "$VM_JSON" ]; then
      warn "[$VM] Failed to get VM details. Skipping."
      continue
    fi
    
    OS_DISK_ID=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.managedDisk.id // empty')
    DATA_DISK_IDS=$(echo "$VM_JSON" | jq -r '.storageProfile.dataDisks[].managedDisk.id // empty')
    NIC_IDS=$(echo "$VM_JSON" | jq -r '.networkProfile.networkInterfaces[].id // empty')

    PIP_IDS=""; NSG_IDS=""; SUBNET_IDS=""
    for NIC in $NIC_IDS; do
      if NIC_JSON=$(az network nic show --ids "$NIC" -o json 2>/dev/null); then
        PIPS=$(echo "$NIC_JSON" | jq -r '.ipConfigurations[].publicIpAddress.id // empty')
        [ -n "$PIPS" ] && PIP_IDS="$PIP_IDS $PIPS"
        NSG=$(echo "$NIC_JSON" | jq -r '.networkSecurityGroup.id // empty')
        [ -n "$NSG" ] && NSG_IDS="$NSG_IDS $NSG"
        SUBNET=$(echo "$NIC_JSON" | jq -r '.ipConfigurations[].subnet.id // empty' | head -n1)
        [ -n "$SUBNET" ] && SUBNET_IDS="$SUBNET_IDS $SUBNET"
      fi
    done

    # Eliminar VM
    log "[$VM] Deleting VM..."
    if ! az vm delete -g "$rg" -n "$VM" --yes --no-wait 2>/dev/null; then
      warn "[$VM] VM deletion failed"
      ((cleanup_errors++))
      continue
    fi

    # Esperar un poco para que la eliminación se propague
    sleep 2

    # Eliminar recursos asociados
    [ -n "$OS_DISK_ID" ] && {
      log "[$VM] Deleting OS disk..."
      az disk delete --ids "$OS_DISK_ID" --yes --no-wait 2>/dev/null || warn "[$VM] OS disk delete failed"
    }
    
    for DID in $DATA_DISK_IDS; do
      [ -n "$DID" ] && {
        log "[$VM] Deleting data disk $DID..."
        az disk delete --ids "$DID" --yes --no-wait 2>/dev/null || true
      }
    done
    
    for NIC in $NIC_IDS; do
      [ -n "$NIC" ] && {
        log "[$VM] Deleting NIC $NIC..."
        az network nic delete --ids "$NIC" --no-wait 2>/dev/null || true
      }
    done
    
    for PIP in $PIP_IDS; do
      [ -n "$PIP" ] && {
        log "[$VM] Deleting Public IP $PIP..."
        az network public-ip delete --ids "$PIP" --no-wait 2>/dev/null || true
      }
    done
    
    for NSG in $NSG_IDS; do
      [ -n "$NSG" ] && {
        log "[$VM] Deleting NSG $NSG..."
        az network nsg delete --ids "$NSG" --no-wait 2>/dev/null || true
      }
    done

    # Limpieza de red si está habilitada
    if [ "${CLEANUP_NETWORK:-0}" -eq 1 ]; then
      for SUB in $SUBNET_IDS; do
        SUB_RG=$(echo "$SUB" | awk -F"/" '{for(i=1;i<=NF;i++){if($i=="resourceGroups"){print $(i+1);break}}}')
        VNET_NAME=$(echo "$SUB" | awk -F"/" '{for(i=1;i<=NF;i++){if($i=="virtualNetworks"){print $(i+1);break}}}')
        SUBNET_NAME=$(echo "$SUB" | awk -F"/" '{for(i=1;i<=NF;i++){if($i=="subnets"){print $(i+1);break}}}')
        LVM=$(echo "$VM" | tr "[:upper:]" "[:lower:]")
        LVN=$(echo "$VNET_NAME" | tr "[:upper:]" "[:lower:]")
        if [[ "$LVN" == "$LVM" || "$LVN" == "$LVM-vnet" || "$LVN" == "$LVMvnet" ]]; then
          log "[$VM] Deleting subnet $SUBNET_NAME in VNet $VNET_NAME..."
          az network vnet subnet delete -g "$SUB_RG" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" --no-wait 2>/dev/null || true
          log "[$VM] Trying to delete VNet $VNET_NAME..."
          az network vnet delete -g "$SUB_RG" -n "$VNET_NAME" --no-wait 2>/dev/null || true
        else
          warn "[$VM] Skipping VNet $VNET_NAME (does not match safe heuristic for VM name)"
        fi
      done
    fi

    log "[$VM] Cleanup initiated."
  done < "$CREATED_VMS_FILE"
  
  if [ $cleanup_errors -gt 0 ]; then
    warn "Cleanup completed with $cleanup_errors errors"
    return 1
  fi
  
  log "Cleanup process completed successfully"
  return 0
}

# Configurar traps - SOLO una trap por señal
trap 'cleanup_function $?' EXIT
trap 'cleanup_function 130' INT
trap 'cleanup_function 143' TERM

# ------------------------- Worklist -------------------------
declare -a WORKLIST=()

if [[ "${SERIES_FILTER,,}" == "all" ]]; then
  build_worklist "all" "$rg" "$LOCATION" WORKLIST
else
  IFS=',' read -r -a _series_list <<< "$SERIES_FILTER"
  for _s in "${_series_list[@]}"; do
    _s_trim="$(echo "$_s" | xargs)"
    [[ -z "$_s_trim" ]] && continue
    build_worklist "$_s_trim" "$rg" "$LOCATION" WORKLIST
  done
fi

pre_run_cleanup_leftovers "$rg" "$CREATED_VMS_FILE" WORKLIST

if [ "${#WORKLIST[@]}" -eq 0 ]; then
  warn "No matching combinations after filtering."
  # El cleanup se ejecutará automáticamente por la trap EXIT
  exit 0
fi

# ---------------------- Parallel exec -----------------------
for tuple in "${WORKLIST[@]}"; do
  IFS='|' read -r series type size offer sku vm_name <<<"$tuple"
  while [ "$(active_jobs)" -ge "$MAX_PARALLEL" ]; do sleep 1; done
  ( run_combo "$series" "$type" "$size" "$offer" "$sku" "$vm_name" ) &
done

# ⚠️ No dejar que 'wait' con exit!=0 pare el script
set +e
wait
wait_status=$?   # (informativo; salimos por BAD_CNT más abajo)
set -e

# -------------------------- Generar estadísticas finales ----------------------------
# Las estadísticas se mostrarán en cleanup_function() al final
log "All tests completed. Processing results..."

# ---------------------- Determinar código de salida -------------------------
BAD_CNT=$(awk -F'|'  '/^BAD\|/{c++}  END{print c+0}' "$RESULTS_LOG"  2>/dev/null)
EXIT_CODE=0
if [ "$BAD_CNT" -gt 0 ]; then
  EXIT_CODE=1
  err "There are BAD tests. Will exit with code 1."
else
  log "All tests passed successfully!"
fi

# ---------------------- Ejecutar cleanup explícitamente -------------------------
log "Executing final cleanup..."
cleanup_function $EXIT_CODE

log "Matrix run finished. See ./artifacts/"
exit $EXIT_CODE