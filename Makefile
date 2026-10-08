SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Tracked AND new-but-not-ignored files: a file that is not committed yet must be linted before the commit, not
# discovered by CI afterwards (happened 2026-10-08 with a new workflow file).
LS_FILES    := git ls-files --cached --others --exclude-standard
SH_FILES    := $(shell $(LS_FILES) '*.sh' 2>/dev/null)
DOCKERFILES := $(shell $(LS_FILES) '*Dockerfile*' 2>/dev/null)
YAML_FILES  := $(shell $(LS_FILES) '*.yml' '*.yaml' '.yamllint' 2>/dev/null)

.PHONY: help lint bootstrap-test

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  %-16s %s\n", $$1, $$2}'
	@if [ -d compose ]; then echo; echo "Compose kit targets: make -C compose help"; fi

bootstrap-test: ## Run scripts/bootstrap-host.sh inside Ubuntu/Debian/Rocky/Alma containers (install-only, ~10 min)
	@tests/bootstrap/test-in-container.sh

lint: ## shellcheck + hadolint + yamllint over tracked files (empty-safe), then compose/ lint if present
	@if [ -n "$(SH_FILES)" ]; then shellcheck -x $(SH_FILES) && echo "shellcheck: OK"; else echo "shellcheck: no .sh files yet"; fi
	@if [ -n "$(DOCKERFILES)" ]; then hadolint $(DOCKERFILES) && echo "hadolint: OK"; else echo "hadolint: no Dockerfiles yet"; fi
	@if [ -n "$(YAML_FILES)" ]; then yamllint -s $(YAML_FILES) && echo "yamllint: OK"; else echo "yamllint: no YAML yet"; fi
	@if [ -f compose/Makefile ]; then $(MAKE) -C compose lint; fi
	@echo "lint: OK"
