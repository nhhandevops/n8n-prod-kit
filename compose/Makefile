# compose/Makefile — the operator interface of the n8n Production Kit (Target A: Docker Compose).
#
# Every target is a thin wrapper around scripts/*.sh or ONE docker compose invocation, so that what `make` does
# is also what a human could type. `make help` lists the targets (built from the `## ` comments below).
#
# The compose command (contract §4) is assembled here EXACTLY like scripts/lib.sh::compose does it:
#   docker compose --project-directory <this dir> --env-file versions.env --env-file .env
#                  -f docker-compose.yml [-f compose.dev.yml when TLS_MODE=internal] [-f compose.scale.yml when it exists]
# versions.env (image pins, written by `make pin`) is loaded first; .env (site settings + secrets, written by `make init`)
# overrides it. Run `make` from anywhere: paths are absolute.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

KIT_DIR  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ENV_FILE := $(KIT_DIR)/.env

# TLS_MODE is read from .env at parse time (a plain grep, no sourcing) — the same rule lib.sh applies.
TLS_MODE := $(shell grep -E '^TLS_MODE=' "$(ENV_FILE)" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d "'\"" )

COMPOSE_FILES := -f $(KIT_DIR)/docker-compose.yml
ifeq ($(TLS_MODE),internal)
COMPOSE_FILES += -f $(KIT_DIR)/compose.dev.yml
endif
ifneq ($(wildcard $(KIT_DIR)/compose.scale.yml),)
COMPOSE_FILES += -f $(KIT_DIR)/compose.scale.yml
endif
COMPOSE := docker compose --project-directory $(KIT_DIR) --env-file $(KIT_DIR)/versions.env --env-file $(ENV_FILE) $(COMPOSE_FILES)

# Variables given on the command line (make init DOMAIN=…) are passed to the scripts as environment — but only when
# set, so a script's `${VAR:-default}` still sees them as unset otherwise.
PASS_VARS := DOMAIN ACME_EMAIL HTTP_PORT HTTPS_PORT FORCE CI YES N8N_VERSION WORKER_REPLICAS SERVICE SINCE NO_COLOR
$(foreach v,$(PASS_VARS),$(if $(value $(v)),$(eval export $(v))))

SINCE ?= 10m

.PHONY: help init pin render preflight config up down restart pull ps logs status dev-ca trust-ca lint version env-keys clean

help: ## Show this help
	@printf 'n8n Production Kit — compose/ targets (run from anywhere: make -C compose <target>)\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "} {printf "  %-12s %s\n", $$1, $$2}'
	@printf '\nTypical first run:  make init DOMAIN=n8n.example.com ACME_EMAIL=you@example.com && make preflight && make up\n'
	@printf 'Local dev (VM/WSL): make init DOMAIN=n8n.localtest.me HTTP_PORT=8080 HTTPS_PORT=8443 && make up && make trust-ca\n'

# --- lifecycle ---------------------------------------------------------------------------------------------------------

init: ## Create .env + secrets for DOMAIN=… [ACME_EMAIL=…] [HTTP_PORT=…] [HTTPS_PORT=…] [FORCE=1]
	@$(KIT_DIR)/scripts/init.sh

pin: ## Resolve image digests into versions.env (make pin N8N_VERSION=x to change the n8n pin)
	@$(KIT_DIR)/scripts/pin.sh

render: ## Generate compose.scale.yml (WORKER_REPLICAS>2) and the Prometheus worker targets
	@$(KIT_DIR)/scripts/render.sh

preflight: ## Check host, .env, ports, DNS, disk, RAM, clock before `up` (exit 1 on any FAIL)
	@$(KIT_DIR)/scripts/preflight.sh

config: ## Print the fully resolved compose configuration
	@$(COMPOSE) config

up: ## preflight → render → pull → (dev: export CA) → compose up --wait → status
	@$(KIT_DIR)/scripts/preflight.sh
	@$(KIT_DIR)/scripts/render.sh
	@$(COMPOSE) pull --quiet
	@if [[ "$(TLS_MODE)" == "internal" ]]; then $(KIT_DIR)/scripts/dev-ca.sh; fi
	@$(COMPOSE) up -d --wait --wait-timeout 240
	@$(KIT_DIR)/scripts/status.sh

down: ## Stop and remove the containers (volumes and .env are kept)
	@$(COMPOSE) down --remove-orphans

restart: ## Restart one service: make restart SERVICE=n8n-worker-1
	@[[ -n "$(SERVICE)" ]] || { echo 'usage: make restart SERVICE=<service>' >&2; exit 2; }
	@$(COMPOSE) restart $(SERVICE)

pull: ## Pull the pinned images
	@$(COMPOSE) pull

ps: ## docker compose ps
	@$(COMPOSE) ps

logs: ## Follow logs: make logs [SERVICE=n8n-main] [SINCE=10m]
	@$(COMPOSE) logs -f --since $(SINCE) $(SERVICE)

status: ## Health table of every service, login URL; exit 1 if anything is unhealthy
	@$(KIT_DIR)/scripts/status.sh

# --- dev TLS -----------------------------------------------------------------------------------------------------------

dev-ca: ## (TLS_MODE=internal) start caddy, wait for its local CA, export secrets/dev-root.crt
	@$(KIT_DIR)/scripts/dev-ca.sh

trust-ca: ## Install/print the dev CA for the host and for a Windows browser
	@$(KIT_DIR)/scripts/trust-ca.sh

# --- quality -----------------------------------------------------------------------------------------------------------

lint: ## shellcheck, yamllint, compose config, caddy validate (all TLS/UI/Kuma combinations)
	@$(KIT_DIR)/scripts/lint.sh

version: ## Kit version (git) and the pinned n8n version
	@printf 'kit  %s\n' "$$(git -C "$(KIT_DIR)" describe --tags --always --dirty 2>/dev/null || echo unknown)"
	@printf 'n8n  %s\n' "$$(grep -E '^N8N_VERSION=' "$(KIT_DIR)/versions.env" | cut -d= -f2)"

env-keys: ## Key NAMES present in .env (values hidden) — paste this into bug reports, never .env itself
	@[[ -f "$(ENV_FILE)" ]] || { echo '.env not found (make init)' >&2; exit 1; }
	@grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$(ENV_FILE)" | cut -d= -f1 | sort

clean: ## DESTROY the stack incl. volumes (database, queue, certs); .env and secrets/ are kept. Asks first.
	@printf '\033[31mThis removes the containers AND the volumes: database, queue, certificates, n8n data.\033[0m\n' >&2
	@printf 'Take a backup first (make backup-now, from S5). .env and secrets/ stay on disk.\n' >&2
	@if [[ "$${CI:-}" != "1" && "$${YES:-}" != "1" ]]; then \
	    read -r -p 'Type "destroy" to continue: ' answer </dev/tty; [[ "$$answer" == "destroy" ]] || { echo 'aborted' >&2; exit 1; }; \
	  fi
	@$(COMPOSE) down -v --remove-orphans
