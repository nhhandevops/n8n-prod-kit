SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

SH_FILES    := $(shell git ls-files '*.sh' 2>/dev/null)
DOCKERFILES := $(shell git ls-files '*Dockerfile*' 2>/dev/null)
YAML_FILES  := $(shell git ls-files '*.yml' '*.yaml' '.yamllint' 2>/dev/null)

.PHONY: help lint

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  %-16s %s\n", $$1, $$2}'
	@if [ -d compose ]; then echo; echo "Compose kit targets: make -C compose help"; fi

lint: ## shellcheck + hadolint + yamllint over tracked files (empty-safe), then compose/ lint if present
	@if [ -n "$(SH_FILES)" ]; then shellcheck $(SH_FILES) && echo "shellcheck: OK"; else echo "shellcheck: no .sh files yet"; fi
	@if [ -n "$(DOCKERFILES)" ]; then hadolint $(DOCKERFILES) && echo "hadolint: OK"; else echo "hadolint: no Dockerfiles yet"; fi
	@if [ -n "$(YAML_FILES)" ]; then yamllint -s $(YAML_FILES) && echo "yamllint: OK"; else echo "yamllint: no YAML yet"; fi
	@if [ -f compose/Makefile ]; then $(MAKE) -C compose lint; fi
	@echo "lint: OK"
