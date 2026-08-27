SHELL := /bin/bash

SCRIPTS := scripts

# A scenario is a file in test_scenarios/; a KCM variant is an id from
# scripts/config/kcm-variants.yaml. `make scenarios` lists both.
SCENARIO ?= 01_basic
KCM      ?= src-main

# Shared by env-up / scenario / env-down so they all address the same cluster.
RUN_ID   ?= local-$(KCM)

E2E := SCENARIO=$(SCENARIO) KCM=$(KCM) RUN_ID=$(RUN_ID) ./$(SCRIPTS)/e2e_test.sh

.PHONY: help
help: ## Show this help.
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Pick with SCENARIO=<stem> KCM=<id>, e.g."
	@echo "  make e2e SCENARIO=02dep01_valid KCM=rel-1-11-0"

.PHONY: scenarios
scenarios: ## List the available scenarios and KCM variants.
	./$(SCRIPTS)/list_scenarios.sh

.PHONY: e2e
e2e: ## One scenario on one KCM variant, from scratch, then tear down.
	$(E2E)

.PHONY: e2e-keep
e2e-keep: ## Same as `e2e` but leaves the environment running.
	$(E2E) --keep

# Building the environment is most of the wall clock, so do it once and run
# every scenario through it. Not a substitute for CI: the scenarios share a
# cluster, so one that wedges it affects the next.
.PHONY: e2e-all
e2e-all: ## Every scenario over ONE environment (KCM installed once).
	@set -e; \
	$(E2E) --env-up; \
	for s in $$(./$(SCRIPTS)/list_scenarios.sh --ids); do \
		echo; echo "══════ scenario $$s ══════"; \
		SCENARIO=$$s KCM=$(KCM) RUN_ID=$(RUN_ID) ./$(SCRIPTS)/e2e_test.sh --scenario-only; \
	done; \
	$(E2E) --env-down

.PHONY: e2e-parallel
e2e-parallel: ## Every scenario at once, each with its own cluster.
	@set -e; \
	pids=""; \
	for s in $$(./$(SCRIPTS)/list_scenarios.sh --ids); do \
		SCENARIO=$$s KCM=$(KCM) RUN_ID=local-$$s ./$(SCRIPTS)/e2e_test.sh & \
		pids="$$pids $$!"; \
	done; \
	rc=0; for p in $$pids; do wait $$p || rc=1; done; exit $$rc

.PHONY: env-up
env-up: ## Build the cluster and KCM, up to a verified child cluster.
	$(E2E) --env-up

.PHONY: scenario
scenario: ## Run one scenario against an environment that is already up.
	$(E2E) --scenario-only

.PHONY: env-down
env-down: ## Tear the environment down.
	$(E2E) --env-down

.PHONY: unit
unit: ## Run the bash unit tests (no cluster required).
	./$(SCRIPTS)/tests/bash/run.sh

.PHONY: lint
lint: ## Run shellcheck over every shell script, and actionlint if installed.
	shellcheck $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh $(SCRIPTS)/tests/bash/*.sh
	@command -v actionlint >/dev/null 2>&1 && actionlint \
		|| echo "actionlint not installed, skipping workflow lint"

.PHONY: deps
deps: ## Verify/install the required CLI tools into .work/bin.
	./$(SCRIPTS)/deps.sh

.PHONY: logs
logs: ## Dump diagnostics from the current environment into ./logs.
	RUN_ID=$(RUN_ID) ./$(SCRIPTS)/collect_logs.sh

.PHONY: clean
clean: ## Tear down containers, network and the working directory.
	RUN_ID=$(RUN_ID) ./$(SCRIPTS)/cleanup.sh
