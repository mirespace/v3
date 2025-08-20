# Makefile for azure-vm-utils orchestrator
SERIES ?= noble
JOBS   ?= 3
ARCH   ?= all        # amd|arm|all
TYPE   ?= all        # e.g., amd64_server,arm64_server
SIZE   ?= all        # e.g., Standard_E2ads_v6
JSON   ?= --json     # empty to disable JSON
CONFIG ?= tests-matrix.json
KEEP   ?=            # set to --keep-vms to skip deletion
CLEANUP_NET ?=       # set to --cleanup-network to enable

.PHONY: run run-all bootstrap clean zip help

help:
	@./run-tests.sh $(CONFIG) --help || true
	@echo ""
	@echo "Targets:"
	@echo "  make run           # run matrix with params (SERIES, JOBS, ARCH, TYPE, SIZE, JSON, KEEP, CLEANUP_NET)"
	@echo "  make run-all       # run all series"
	@echo "  make bootstrap     # check deps (jq, az) and login if needed"
	@echo "  make clean         # remove artifacts/"
	@echo "  make zip           # build release zip azure-vm-utils-release.zip"
	@echo ""
	@echo "Examples:"
	@echo "  make run SERIES=jammy JOBS=1 TYPE=amd64_server SIZE=Standard_E2ads_v6 JSON=--json"
	@echo "  make run-all TYPE=arm64_server JSON=--json"

run:
	chmod +x run-tests.sh
	./run-tests.sh $(CONFIG) --series $(SERIES) --max-parallel $(JOBS) --arch $(ARCH) --type $(TYPE) --size $(SIZE) $(KEEP) $(JSON) $(CLEANUP_NET)

run-all:
	chmod +x run-tests.sh
	./run-tests.sh $(CONFIG) --series all --max-parallel $(JOBS) --arch $(ARCH) --type $(TYPE) --size $(SIZE) $(KEEP) $(JSON) $(CLEANUP_NET)

bootstrap:
	@command -v jq >/dev/null 2>&1 || (echo "Installing jq..." && sudo apt-get update -y && sudo apt-get install -y jq)
	@command -v az >/dev/null 2>&1 || (echo "Azure CLI 'az' not found"; exit 1)
	@az account show >/dev/null 2>&1 || az login --use-device-code

clean:
	rm -rf artifacts

zip:
	rm -f azure-vm-utils-release.zip
	zip -r azure-vm-utils-release.zip . -x "*.git*" -x "artifacts/*"
	@sha256sum azure-vm-utils-release.zip || shasum -a 256 azure-vm-utils-release.zip || true
