# Azure VM Utils – Test Orchestrator

**What you get**
- Bash orchestrator to spin up Ubuntu VMs on Azure, run a 3-phase test plan, collect metrics, and emit JSON summaries.
- Parallel runs, filtering by series/type/size, architecture inference, colored logs, and resource cleanup.
- Policy engine that turns metric expectations into BAD when not met.

## Features
- **Filters**: `--series`, `--type`, `--size`, `--arch` (optional; inferred from `--type`).
- **Parallelism**: `--max-parallel N`.
- **JSON summary**: `--json [path]` (default `artifacts/summary.json`) + `lib/json_summary.sh`.
- **3 phases**: prechecks → install/update `azure-vm-utils` from `-proposed` + networkd debug + reboot → postchecks.
- **Metrics**: emit `METRIC:key=value` lines in tests; parser collects them per test and rolls up per VM.
- **Policies** (in `lib/vm_test_lib.sh`): enforce driver/NVMe expectations by *size* & *arch*, and phase-2 invariants.
- **Colored logs**: INFO (blue), WARN (yellow), ERROR (red), COMMAND (cyan), TEST (blue). Disable with `NO_COLOR=1`.
- **Quiet SSH**: silences “Permanently added … known hosts” via `-o LogLevel=ERROR` and ephemeral known_hosts.
- **Cleanup**: delete VMs and attached resources at the end; `--keep-vms` skips that; `--cleanup-network` tries VNet/subnet cleanup (safe heuristic).
- **Gen2-only images**: image catalog uses `*-gen2` SKUs. Availability checked per region; combos not available are **SKIP**ped.

## Quickstart
```bash
make bootstrap
# AMD: jammy + amd64_server + E2ads_v6
make run SERIES=jammy TYPE=amd64_server SIZE=Standard_E2ads_v6 JSON=--json JOBS=1
# ARM: noble + arm64_server + E2pds_v6
make run SERIES=noble TYPE=arm64_server SIZE=Standard_E2pds_v6 JSON=--json JOBS=1
# All sizes for a type (arch inferred)
./run-tests.sh tests-matrix.json --series jammy --type amd64_server --max-parallel 1 --json
```

## Help
```bash
./run-tests.sh tests-matrix.json --help
```
- Lists accepted `series`, `types`, `sizes`, and the `series/type -> offer:sku` mapping from the JSON.
- Includes explanation of `--size` vs **labels** (labels are used in VM names/tags, not for selection).

## Artifacts
- `artifacts/_results_summary.log` → `GOOD|BAD` lines per test.
- `artifacts/_skip_summary.log` → reasons for SKIPs (catalog/img availability, VM create/IP/SSH issues, etc.).
- `artifacts/<vm>/<test>/stdout.log` → test logs with `METRIC:` lines.
- `artifacts/summary.json` → aggregate JSON with totals, results, skips, metrics, and per-VM rollup.

## Cleanup
- By default, the orchestrator deletes VMs it created (tracked in `artifacts/_created_vms.list`).
- Use `--keep-vms` to skip deletion (for debugging).
- Add `--cleanup-network` to also attempt subnet/VNet deletion when it’s safe to do so.

## Policy engine (data-driven)

Las políticas se definen en `tests-matrix.json` bajo `"policies"`. El runner evalúa reglas **sin cambiar código**.

### Estructura
- `global`: reglas que aplican a todas las combinaciones (con `when` opcional).
- `by_combo`: reglas filtradas por combinación usando `match`:
  - `type_glob` (glob bash, p. ej. `amd64_*`)
  - `series` (opcional, exacto)
  - `size` (exacto) o `size_in` (lista exacta)

Cada regla puede tener:
- `when`: **todas** las condiciones deben cumplirse para evaluar la regla (si no, se ignora).
- `require`: puede ser una condición simple o grupos:
  - `{"metric":"...", "op":"...", "value": ...}`
  - `{"all_of": [ ... ]}`  (todas verdaderas)
  - `{"any_of":  [ ... ]}` (alguna verdadera)
  - Puede haber **anidación** de `any_of` dentro de `all_of`, etc.

### Operadores soportados
- Numéricos/strings: `eq`, `ne`, `gt`, `lt`, `gte`, `lte`
- Strings: `contains`, `ncontains`, `regex`, `in` (ej: `"a,b,c"`)

### Ejemplos de ajuste (sin tocar código)
**1) Relajar requisito de reglas en initrd:**
```json
{ "metric": "initrd_azure_rules", "op": "gte", "value": 0 }
```
**2)Limitar cambios de red tras reboot:**
```json
{
  "name": "limit_network_diff",
  "message": "Too many link changes after reboot",
  "require": {
    "all_of": [ { "metric": "network_diff_lines", "op": "lte", "value": 50 } ]
  }
}
```
**3) Aceptar MANA o MLX en E2ads (cualquiera de los dos):**
```json
"require": {
  "all_of": [
    { "any_of": [
      { "metric": "has_nvme_v2",     "op": "eq", "value": 1 },
      { "metric": "has_nvme_legacy", "op": "eq", "value": 1 }
    ]},
    { "any_of": [
      { "metric": "net_has_mlx",  "op": "eq", "value": 1 },
      { "metric": "net_has_mana", "op": "eq", "value": 1 }
    ]}
  ]
}
```
**4) Restringir versión mínima de azure-vm-utils:**
```json
{
  "name": "min_azure_vm_utils",
  "message": "azure-vm-utils version too low",
  "require": { "regex": "azure_vm_utils_version", "op": "regex", "value": "^1\\.2\\." }
}
```
