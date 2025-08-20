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
```
