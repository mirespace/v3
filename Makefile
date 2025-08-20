run-quick: validate
	@echo "Running quick validation tests..."
	chmod +x run-tests.sh
	bash ./run-tests.sh $(CONFIG) \
		--series $(SERIES) \
		--max-parallel 2 \
		--type amd64_server# Makefile for azure-vm-utils orchestrator - Enhanced version
SERIES ?= noble
JOBS   ?= 3
ARCH   ?= all        # amd|arm|all
TYPE   ?= all        # e.g., amd64_server,arm64_server
SIZE   ?= all        # e.g., Standard_E2ads_v6
JSON   ?= --json     # empty to disable JSON
CONFIG ?= tests-matrix.json
KEEP   ?=            # set to --keep-vms to skip deletion
CLEANUP_NET ?=       # set to --cleanup-network to enable
TIMEOUT_MULT ?= 1.0  # timeout multiplier
DRY_RUN ?=           # set to --dry-run for cost estimation

# Advanced options
REGION_PREF ?= eastus # preferred region for new resource groups
LOG_LEVEL ?= INFO    # INFO|DEBUG|WARN|ERROR

.PHONY: run run-all run-quick run-arm run-amd bootstrap clean zip help validate monitor

help:
	@echo "Enhanced Azure VM Utils Test Orchestrator"
	@echo ""
	@echo "Basic targets:"
	@echo "  make run           # run matrix with params (SERIES, JOBS, ARCH, TYPE, SIZE, etc.)"
	@echo "  make run-all       # run all series with current filters"
	@echo "  make run-quick     # run minimal AMD64 test for quick validation"
	@echo "  make run-quick-arm # run minimal ARM64 test for quick validation"
	@echo "  make run-quick-both# run quick tests for both architectures"
	@echo "  make run-arm       # run ARM64-specific tests"
	@echo "  make run-amd       # run AMD64-specific tests"
	@echo ""
	@echo "Utility targets:"
	@echo "  make bootstrap     # check deps (jq, az) and login if needed"
	@echo "  make validate      # validate configuration without running tests"
	@echo "  make monitor       # monitor running tests (requires JSON output)"
	@echo "  make clean         # remove artifacts/"
	@echo "  make zip           # build release zip azure-vm-utils-release.zip"
	@echo ""
	@echo "Parameters:"
	@echo "  SERIES=$(SERIES)          # ubuntu series to test"
	@echo "  JOBS=$(JOBS)              # max parallel VMs"
	@echo "  ARCH=$(ARCH)              # filter by architecture"
	@echo "  TYPE=$(TYPE)              # filter by VM type"
	@echo "  SIZE=$(SIZE)              # filter by VM size"
	@echo "  TIMEOUT_MULT=$(TIMEOUT_MULT)      # multiply timeouts by this factor"
	@echo ""
	@echo "Flags:"
	@echo "  JSON=$(JSON)              # enable JSON output"
	@echo "  KEEP=$(KEEP)              # keep VMs after tests"
	@echo "  CLEANUP_NET=$(CLEANUP_NET)      # cleanup networks"
	@echo "  DRY_RUN=$(DRY_RUN)            # dry run for cost estimation"
	@echo ""
	@bash ./run-tests.sh $(CONFIG) --help 2>/dev/null || echo "Note: run 'make bootstrap' first to see detailed help"

# Validation target
validate:
	@echo "Validating configuration..."
	@command -v jq >/dev/null 2>&1 || (echo "Installing jq..." && sudo apt-get update -y && sudo apt-get install -y jq)
	@if [ ! -f "$(CONFIG)" ]; then echo "ERROR: Config file $(CONFIG) not found"; exit 1; fi
	@echo "✓ Config file exists"
	@jq empty $(CONFIG) || (echo "ERROR: Invalid JSON in $(CONFIG)"; exit 1)
	@echo "✓ Valid JSON syntax"
	@jq -e '.resource_group' $(CONFIG) >/dev/null || (echo "ERROR: Missing resource_group"; exit 1)
	@echo "✓ Required fields present"
	@jq -r '.matrix.series[] | "  - \(.)"' $(CONFIG) | head -5
	@echo "✓ Configuration validated successfully"

# Cost estimation target
estimate: validate
	@echo "Estimating costs for planned execution..."
	chmod +x run-tests.sh
	./run-tests.sh $(CONFIG) \
		--series $(SERIES) \
		--max-parallel $(JOBS) \
		--arch $(ARCH) \
		--type $(TYPE) \
		--size $(SIZE) \
		--timeout-multiplier $(TIMEOUT_MULT) \
		--dry-run \
		$(JSON) || true

# Cost-aware run with safety check
run: validate
	chmod +x run-tests.sh
	bash ./run-tests.sh $(CONFIG) \
		--series $(SERIES) \
		--max-parallel $(JOBS) \
		--arch $(ARCH) \
		--type $(TYPE) \
		--size $(SIZE) \
		--timeout-multiplier $(TIMEOUT_MULT) \
		$(KEEP) $(JSON) $(CLEANUP_NET) $(DRY_RUN)

# Predefined test scenarios
run-all: validate
	chmod +x run-tests.sh
	bash ./run-tests.sh $(CONFIG) \
		--series all \
		--max-parallel $(JOBS) \
		--arch $(ARCH) \
		--type $(TYPE) \
		--size $(SIZE) \
		--timeout-multiplier $(TIMEOUT_MULT) \
		$(KEEP) $(JSON) $(CLEANUP_NET)

run-quick: validate
	@echo "Running quick validation tests..."
	chmod +x run-tests.sh
	bash ./run-tests.sh $(CONFIG) \
		--series $(SERIES) \
		--max-parallel 2 \
		--type amd64_server \
		--size Standard_D2ls_v6 \
		--timeout-multiplier 0.8 \
		$(JSON) $(CLEANUP_NET)

run-quick-arm: validate
	@echo "Running quick ARM64 validation tests..."
	chmod +x run-tests.sh
	bash ./run-tests.sh $(CONFIG) \
		--series $(SERIES) \
		--max-parallel 2 \
		--type arm64_server \
		--size Standard_D2pds_v6 \
		--timeout-multiplier 0.8 \
		$(JSON) $(CLEANUP_NET)

run-quick-both: validate
	@echo "Running quick tests for both architectures..."
	$(MAKE) run-quick SERIES=$(SERIES) JSON=$(JSON)
	$(MAKE) run-quick-arm SERIES=$(SERIES) JSON=$(JSON)

run-arm: validate
	@echo "Running ARM64-specific tests..."
	chmod +x run-tests.sh
	bash ./run-tests.sh $(CONFIG) \
		--series $(SERIES) \
		--max-parallel $(JOBS) \
		--arch arm \
		--size Standard_E2pds_v6,Standard_D2pds_v6,Standard_D2plds_v6 \
		--timeout-multiplier $(TIMEOUT_MULT) \
		$(KEEP) $(JSON) $(CLEANUP_NET)

run-amd: validate
	@echo "Running AMD64-specific tests..."
	chmod +x run-tests.sh
	bash ./run-tests.sh $(CONFIG) \
		--series $(SERIES) \
		--max-parallel $(JOBS) \
		--arch amd \
		--size Standard_E2ads_v6,Standard_D2alds_v6,Standard_D2ls_v6 \
		--timeout-multiplier $(TIMEOUT_MULT) \
		$(KEEP) $(JSON) $(CLEANUP_NET)

# Enhanced bootstrap with region preference
bootstrap:
	@echo "Enhanced bootstrap process..."
	@command -v jq >/dev/null 2>&1 || (echo "Installing jq..." && sudo apt-get update -y && sudo apt-get install -y jq)
	@command -v az >/dev/null 2>&1 || (echo "Azure CLI 'az' not found"; exit 1)
	@echo "✓ Dependencies available"
	@az account show >/dev/null 2>&1 || az login --use-device-code
	@echo "✓ Azure CLI authenticated"
	@if [ -f "$(CONFIG)" ]; then \
		RG=$$(jq -r '.resource_group' $(CONFIG)); \
		if ! az group show --name "$$RG" >/dev/null 2>&1; then \
			echo "⚠️  Resource group $$RG does not exist"; \
			echo "   Create it with: az group create --name $$RG --location $(REGION_PREF)"; \
		else \
			echo "✓ Resource group $$RG exists"; \
		fi \
	fi
	@echo "✅ Bootstrap completed"

# Real-time monitoring (requires JSON output enabled)
monitor:
	@if [ ! -f "artifacts/summary.json" ]; then \
		echo "No summary.json found. Enable JSON output with JSON=--json"; \
		exit 1; \
	fi
	@echo "Monitoring test execution..."
	@while [ $$(jobs -r | wc -l) -gt 0 ] || [ ! -f artifacts/_results_summary.log ]; do \
		if [ -f artifacts/_results_summary.log ]; then \
			GOOD=$$(grep -c '^GOOD|' artifacts/_results_summary.log 2>/dev/null || echo 0); \
			BAD=$$(grep -c '^BAD|' artifacts/_results_summary.log 2>/dev/null || echo 0); \
			SKIP=$$(wc -l < artifacts/_skip_summary.log 2>/dev/null | tr -d ' ' || echo 0); \
			printf "\r[%s] Status: %d GOOD, %d BAD, %d SKIP" "$$(date '+%H:%M:%S')" "$$GOOD" "$$BAD" "$$SKIP"; \
		else \
			printf "\r[%s] Waiting for tests to start..." "$$(date '+%H:%M:%S')"; \
		fi; \
		sleep 3; \
	done
	@echo ""
	@echo "✅ Monitoring complete"

# Analysis target for completed runs
analyze:
	@if [ ! -f "artifacts/summary.json" ]; then \
		echo "No summary.json found. Run tests with JSON=--json first."; \
		exit 1; \
	fi
	@echo "=== TEST ANALYSIS ==="
	@echo "Success Rate: $$(jq -r '.totals.success_rate // 0' artifacts/summary.json)%"
	@echo "Total VMs: $$(jq -r '.performance_stats.total_vms // 0' artifacts/summary.json)"
	@echo "Critical Skips: $$(jq -r '.summary_stats.critical_skips // 0' artifacts/summary.json)"
	@echo "Policy Failures: $$(jq -r '.summary_stats.policy_failures // 0' artifacts/summary.json)"
	@echo ""
	@echo "Most Common Failures:"
	@jq -r '.summary_stats.most_common_failures[]? | "  \(.category): \(.count) cases"' artifacts/summary.json || echo "  None"
	@echo ""
	@echo "By Series:"
	@jq -r '.summary_stats.by_series | to_entries[]? | "  \(.key): \(.value) tests"' artifacts/summary.json || echo "  No data"

# Performance benchmark
benchmark: clean
	@echo "Running performance benchmark..."
	@START_TIME=$(date +%s); \
	$(MAKE) run-quick JSON=--json JOBS=4 SERIES=noble TYPE=amd64_server SIZE=Standard_D2ls_v6; \
	END_TIME=$(date +%s); \
	DURATION=$((END_TIME - START_TIME)); \
	echo ""; \
	echo "=== BENCHMARK RESULTS ==="; \
	echo "Duration: ${DURATION}s"; \
	if [ -f "artifacts/summary.json" ]; then \
		echo "Success Rate: $(jq -r '.totals.success_rate // 0' artifacts/summary.json)%"; \
		echo "Total Tests: $(jq -r '.totals.total // 0' artifacts/summary.json)"; \
	fi; \
	echo "========================="f "artifacts/summary.json" ]; then \
		echo "Success Rate: $$(jq -r '.totals.success_rate // 0' artifacts/summary.json)%"; \
		echo "Total Tests: $$(jq -r '.totals.total // 0' artifacts/summary.json)"; \
	fi; \
	echo "========================="

clean:
	rm -rf artifacts/
	@echo "✓ Cleaned artifacts directory"

# Enhanced zip target with version info
zip: clean
	@VERSION=$$(date +%Y%m%d-%H%M%S); \
	ZIP_NAME="azure-vm-utils-release-$$VERSION.zip"; \
	rm -f azure-vm-utils-release*.zip; \
	echo "Creating release: $$ZIP_NAME"; \
	zip -r "$$ZIP_NAME" . \
		-x "*.git*" -x "artifacts/*" -x "*.zip" \
		-x "*.log" -x "*~" -x "*.tmp"; \
	if command -v sha256sum >/dev/null 2>&1; then \
		sha256sum "$$ZIP_NAME" > "$$ZIP_NAME.sha256"; \
		echo "✓ Created $$ZIP_NAME with checksum"; \
	else \
		echo "✓ Created $$ZIP_NAME"; \
	fi

# CI/CD targets
ci-test: validate
	@echo "Running CI test suite..."
	$(MAKE) run-quick JSON=--json TIMEOUT_MULT=1.5

ci-full: validate  
	@echo "Running full CI test suite..."
	$(MAKE) run-all JSON=--json TIMEOUT_MULT=1.2

# Development helpers
dev-setup: bootstrap
	@echo "Setting up development environment..."
	@if [ ! -f ".env" ]; then \
		echo "# Development environment variables" > .env; \
		echo "SERIES=noble" >> .env; \
		echo "JOBS=2" >> .env; \
		echo "JSON=--json" >> .env; \
		echo "✓ Created .env file"; \
	fi
	@echo "✅ Development setup complete"

# Include local overrides if present
-include Makefile.local