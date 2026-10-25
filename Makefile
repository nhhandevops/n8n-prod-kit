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
	@# The docs site is built with --strict so a dead internal link or a page missing from the nav fails here
	@# rather than on the site. Skipped when mkdocs is not installed (CI always has it; see .github/workflows/docs.yml).
	@if [ -f mkdocs.yml ]; then 		if command -v mkdocs >/dev/null 2>&1; then mkdocs build --strict --quiet && echo "mkdocs: OK"; 		else echo "mkdocs: not installed, skipped (pip install -r requirements-docs.txt)"; fi; 	fi
	@echo "lint: OK"

# Everything else this kit does lives in compose/Makefile, so `make smoke`, `make restore` or
# `make rotate-recovery-key` typed at the repository root gets GNU make's bare "No rule to make target",
# which reads like a broken checkout. It is not: it is a missing -C compose. That cost two round trips on
# 2026-10-25, so the error now names the command to type instead.
.DEFAULT:
	@if [ -f compose/Makefile ] && grep -qE "^$@:" compose/Makefile; then \
	  printf '"%s" is a Compose-kit target, not a root one. Run:\n\n    make -C compose %s\n\n' "$@" "$@" >&2; \
	else \
	  printf 'no "%s" target here. This Makefile has: help, lint, bootstrap-test.\nThe Compose kit has the rest: make -C compose help\n' "$@" >&2; \
	fi; \
	exit 2
