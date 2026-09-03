SHELL := /bin/bash

SCRIPTS := scripts

# A scenario is a file in test_scenarios/; a KCM variant is an id from
# scripts/config/kcm-variants.yaml. `make scenarios` lists both.
SCENARIO ?= 01_basic
# Deliberately empty: forcing a variant here would override an explicit
# KCM_VERSION/KCM_MODE and silently test something else. Empty means the
# defaults in common.sh apply -- release 1.11.0.
KCM      ?=

# Shared by env-up / scenario / env-down so they all address the same cluster,
# and distinct per configuration so two of them can coexist. Dots become dashes:
# it ends up in CLD_NAME, which is a DNS label.
RUN_ID   ?= local$(if $(KCM),-$(KCM))$(if $(KCM_MODE),-$(KCM_MODE))$(if $(KCM_VERSION),-$(subst .,-,$(KCM_VERSION)))

E2E := SCENARIO=$(SCENARIO) KCM=$(KCM) RUN_ID=$(RUN_ID) ./$(SCRIPTS)/e2e_test.sh

.PHONY: help
help: ## Show this help.
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Defaults to the published chart $(shell KCM= bash -c 'source scripts/lib/common.sh; echo $$KCM_VERSION'). Pick with:"
	@echo "  make e2e SCENARIO=02dep01_valid KCM=rel-1-11-0   # a variant CI tests"
	@echo "  make e2e SCENARIO=02dep01_valid KCM_VERSION=1.10.0"
	@echo "  make e2e SCENARIO=02dep01_valid KCM_MODE=source KCM_REF=<branch|tag|sha>"
	@echo
	@echo "Detail and examples for one target:  make <target>-help"
	@echo "make scenarios lists the scenarios and variants; make status what is built."

# Per-target usage lives in `#:` comments right above each target, so it sits
# next to the recipe it documents and cannot drift from the target list.
%-help:
	@awk -v t="$*" ' \
	    /^#:/  { buf = buf substr($$0, 4) "\n"; next } \
	    $$0 ~ "^" t ":" { \
	        sub(/.*## /, ""); \
	        printf "\033[36m%s\033[0m -- %s\n\n%s", t, $$0, buf; found = 1; exit \
	    } \
	    { buf = "" } \
	    END { if (!found) printf "No target %s. Run make help for the list.\n", t } \
	' $(MAKEFILE_LIST)

.PHONY: scenarios
scenarios: ## List the available scenarios and KCM variants.
	./$(SCRIPTS)/list_scenarios.sh

# No RUN_ID: the point is to show every environment, not the selected one.
.PHONY: status
#: Every environment that exists, whichever RUN_ID built it: which clusters
#: are up, what KCM is installed, and what to pass to reuse it. Also lists
#: working directories whose clusters are gone.
#:
#: Vars: none -- it deliberately ignores the current selection.
status: ## Show which environments are built, and how to reuse them.
	./$(SCRIPTS)/status.sh

.PHONY: e2e
#: Everything in one go: build the environment, run the scenario, tear it
#: down. Roughly 10 minutes, most of it the build.
#:
#: Vars: SCENARIO (default 01_basic), and one of KCM / KCM_VERSION / KCM_MODE
#:       to choose the KCM under test. Defaults to the published 1.11.0.
#:
#:   make e2e SCENARIO=02dep01_valid
#:   make e2e SCENARIO=02dep01_valid KCM=rel-1-10-0
#:   make e2e SCENARIO=01_basic KCM_MODE=source KCM_REF=my-branch
#:
#: See also: e2e-keep (leave it running), env-up + scenario (reuse it).
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
#: Builds both k0s clusters, installs KCM and adopts the child cluster.
#: About 7 minutes. Stops before any scenario runs.
#:
#: Vars: KCM / KCM_VERSION / KCM_MODE -- these also derive RUN_ID, so pass the
#:       same ones to `scenario` and `env-down` or you will address a different
#:       environment. `make status` shows what you already have.
#:
#:   make env-up
#:   make env-up KCM=rel-1-10-0
#:   make env-up KCM_MODE=source KCM_SRC_URL=https://github.com/me/kcm.git KCM_REF=480aad76
env-up: ## Build the cluster and KCM, up to a verified child cluster.
	$(E2E) --env-up

.PHONY: scenario
#: Deploys the scenario's services through a MultiClusterService, verifies
#: them and removes them again. Needs `make env-up` first.
#:
#: Vars: SCENARIO, plus the same KCM selection you built the environment with,
#:       or RUN_ID directly as `make status` prints it.
#:
#:   make scenario SCENARIO=02dep01_valid KCM=rel-1-10-0
#:   make scenario SCENARIO=02dep01_valid RUN_ID=local-rel-1-10-0
#:
#: Scenarios are not isolated from each other on a shared environment:
#: 02dep02_invalid breaks cert-manager on purpose.
scenario: ## Run one scenario against an environment that is already up.
	$(E2E) --scenario-only

.PHONY: scenario-keep
#: Same as `scenario` but stops before removing the services, so you can
#: look at them. `make scenario-clean` removes them afterwards.
#:
#: Vars: as `scenario`.
#:
#:   make scenario-keep SCENARIO=02dep01_valid
#:   kubectl --kubeconfig kcfg_adopted<-RUN_ID> get pods -A
scenario-keep: ## Run scenario, leave services deployed.
	$(E2E) --scenario-only --keep-resources

.PHONY: scenario-clean
#: Removes the services a `scenario-keep` run left behind, and runs the same
#: teardown assertions `scenario` would have.
#:
#: Vars: as `scenario` -- the same SCENARIO, or it will look for the wrong
#:       MultiClusterService.
scenario-clean: ## Remove services from a kept scenario.
	$(E2E) --scenario-only --clean-only

.PHONY: env-down
#: Removes the containers, network and kubeconfigs of ONE environment. The
#: working directory stays; `make clean` removes that too.
#:
#: Vars: RUN_ID, or the same KCM / KCM_VERSION / KCM_MODE you built with --
#:       RUN_ID is derived from them, and that is what names the clusters.
#:
#:   make env-down                        # the default environment
#:   make env-down KCM=rel-1-10-0
#:   make env-down RUN_ID=credfix         # exactly what `make status` printed
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
#: Dumps controller logs, events and object state into ./logs<-RUN_ID>.
#: Run it before tearing a failed environment down.
#:
#: Vars: RUN_ID, as `make status` prints it.
logs: ## Dump diagnostics from the current environment into ./logs.
	RUN_ID=$(RUN_ID) ./$(SCRIPTS)/collect_logs.sh

.PHONY: clean
#: Like `env-down` plus the working directory, so nothing of the run is left.
#: Use it on the leftovers `make status` lists under "no cluster".
#:
#: Vars: RUN_ID.
#:
#:   make clean RUN_ID=local-rel-1-10-0
clean: ## Tear down containers, network and the working directory.
	RUN_ID=$(RUN_ID) ./$(SCRIPTS)/cleanup.sh
