# Azure VM Utils – Enhanced Test Orchestrator

**What you get**
- Robust Bash orchestrator to spin up Ubuntu VMs on Azure, run a 3-phase test plan, collect metrics, and emit comprehensive JSON summaries
- **NEW**: Adaptive timeouts, intelligent SSH retry, cost estimation, and enhanced monitoring
- **NEW**: Improved error handling, structured logging, and safer network cleanup
- **ENHANCED**: Data-driven policy engine with flexible rules and better validation

## 🚀 New Features in v2.0

### **Smart Infrastructure Management**
- **Adaptive Timeouts**: Automatically adjusts SSH and VM power timeouts based on region and VM size
- **Intelligent Retry**: SSH connections retry with exponential backoff and connection loss detection
- **Safe Network Cleanup**: Enhanced validation before deleting VNets and subnets

### **Enhanced Monitoring**
- **Structured Logging**: JSON-formatted logs with correlation IDs
- **Real-time Progress**: Live monitoring of test execution
- **Performance Analytics**: Detailed timing and resource utilization metrics

### **Improved Reliability**
- **Robust Configuration Validation**: Early detection of invalid configurations
- **Better Error Classification**: Categorized failures for easier troubleshooting
- **Enhanced JSON Output**: Richer summary data with trend analysis

## Features

- **Filters**: `--series`, `--type`, `--size`, `--arch` (inferred from `--type`)
- **Parallelism**: `--max-parallel N` with intelligent progress monitoring
- **JSON summary**: Enhanced `--json [path]` with performance metrics and failure analysis
- **3 phases**: prechecks → install/update `azure-vm-utils` from `-proposed` + networkd debug + reboot → postchecks
- **Metrics**: emit `METRIC:key=value` lines; parser collects and aggregates per VM
- **Policies**: data-driven validation engine with flexible rules and timing controls
- **Colored logs**: INFO (blue), WARN (yellow), ERROR (red), COMMAND (cyan), TEST (blue)
- **Safe cleanup**: intelligent resource deletion with multiple safety checks
- **Gen2-only images**: uses `*-gen2` SKUs with availability validation

## Quickstart

```bash
# Enhanced bootstrap with validation
make bootstrap

# Quick validation run (AMD64 only)
make run-quick

# Quick validation for ARM64 
make run-quick-arm

# Test both architectures sequentially
make run-quick-both

# AMD example with valid combination
make run SERIES=jammy TYPE=amd64_server SIZE=Standard_E2ads_v6 JSON=--json JOBS=1

# ARM example with valid combination  
make run SERIES=noble TYPE=arm64_server SIZE=Standard_E2pds_v6 JSON=--json JOBS=1

# Dry run for configuration validation
./run-tests.sh tests-matrix.json --series jammy --type amd64_server --size Standard_D2ls_v6 --dry-run

# Full test suite for specific architectures
make run-amd TIMEOUT_MULT=1.2
make run-arm TIMEOUT_MULT=1.2
```

## Enhanced Command Line Options

```bash
./run-tests.sh tests-matrix.json [options]

# Basic options
--series <name|all>         # Filter by Ubuntu series
--arch amd|arm|all          # Filter by architecture
--type <a,b,c|all>          # Filter by VM types (comma-separated)
--size <a,b,c|all>          # Filter by VM sizes (comma-separated)
--max-parallel <N>          # Max concurrent VMs

# New reliability options
--timeout-multiplier <N>    # Multiply base timeouts (default: 1.0)
--dry-run                   # Configuration validation without VM creation
--keep-vms                  # Preserve VMs for debugging
--cleanup-network           # Safe network resource cleanup

# Output options
--json [path]               # Enhanced JSON summary with analytics
```

## Cost Management

### **Cost Estimation**
```bash
# Estimate costs for a test run
make estimate SERIES=jammy TYPE=amd64_server

# Output example:
# ===== COST ESTIMATION =====
# Total VMs to create: 3
# Standard_E2ads_v6   x 2 = $0.2016/hour
# Standard_D2ls_v6    x 1 = $0.0960/hour
# TOTAL ESTIMATED COST: $0.2976/hour
# Estimated duration: 0.50h
# ESTIMATED TOTAL COST: $0.15
```

### **Budget Controls**
```bash
# Set cost limits
make run MAX_COST=10.00    # Abort if estimated cost > $10
make run-all MAX_COST=50.00 TIMEOUT_MULT=1.5
```

## Enhanced Artifacts Structure

```
artifacts/
├── summary.json              # Comprehensive test summary with analytics
├── _results_summary.log      # GOOD|BAD results with detailed failure info
├── _skip_summary.log         # Categorized skip reasons
├── _created_vms.list        # VM tracking for cleanup
└── <vm>/
    └── <test>/
        └── stdout.log        # Test output with enhanced METRIC: lines
```

## Enhanced JSON Summary

The improved JSON output includes:

```json
{
  "_version": "2.0",
  "run": {
    "timestamp": "2025-01-XX...",
    "runner_host": "hostname",
    "azure_subscription": "sub-id",
    "correlation_id": "1234567-890"
  },
  "totals": {
    "GOOD": 15, "BAD": 2, "SKIP": 3,
    "success_rate": 88,
    "completion_rate": 85
  },
  "summary_stats": {
    "by_failure_category": {"policy": 1, "connectivity": 1},
    "critical_skips": 2,
    "most_common_failures": [...]
  },
  "performance_stats": {
    "total_vms": 20,
    "avg_duration_minutes": 28,
    "completion_rate": 85
  }
}
```

## Enhanced Policy Engine

### **Flexible Rule Definition**
```json
{
  "policies": {
    "global": [
      {
        "name": "network_stability_after_reboot",
        "message": "Network should be stable after reboot",
        "require": {
          "all_of": [
            {"metric": "network_diff_lines", "op": "lte", "value": 50},
            {"metric": "network_changed_links", "op": "lte", "value": 10}
          ]
        },
        "phase_at_least