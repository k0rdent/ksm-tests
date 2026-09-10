SHELL := /bin/bash

SCRIPTS := scripts

# A scenario is a file in test_scenarios/; a KCM variant is an id from
# scripts/config/kcm-variants.yaml. `make scenarios` lists both.
SCENARIO ?= 01_basic
# Deliberately empty: forcing a variant here would override an explicit
# KCM_VERSION/KCM_MODE and silently test something else. Empty means the
# defaults in common.sh apply -- release 1.11.0.
KCM      ?=

# Empty by default: one environment, under plain names, the way catalog does
# it -- the cluster is kcm-mgmt and its kubeconfig is ./kcfg_k0rdent, so
# `export KUBECONFIG=kcfg_k0rdent` is all it takes to poke at it by hand.
# Which KCM is in it is recorded in .work/kcm-build.env, so `scenario` and
# `env-down` need nothing repeated.
#
# Set RUN_ID to hold several environments at once; e2e-parallel does that,
# and CI gives each job its own.
RUN_ID   ?=

E2E := SCENARIO=$(SCENARIO) KCM=$(KCM) RUN_ID=$(RUN_ID) ./$(SCRIPTS)/e2e_test.sh

# `make env-up help` explains the target instead of running it. make takes its
# arguments as a list of goals, so without this it would build the cluster and
# print the help afterwards. The real rules are not defined at all in this mode:
# defining them and overriding later would turn a missed override into a
# seven-minute cluster build.
HELP_FOR := $(if $(filter help,$(MAKECMDGOALS)),$(filter-out help,$(MAKECMDGOALS)))
ifneq ($(HELP_FOR),)

.PHONY: help $(HELP_FOR)
# A no-op recipe, not an empty one: an empty one still prints "Nothing to be
# done for 'help'" after the text the user asked for.
help:
	@:
$(HELP_FOR):
	@$(MAKE) --no-print-directory $@-help

else

.PHONY: help
help: ## Show this help.
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "One environment: cluster kcm-mgmt, kubeconfig ./kcfg_k0rdent."
	@echo "KCM says what to install; only env-up and e2e need it."
	@echo
	@echo "  make e2e SCENARIO=02dep01_valid                     # chart $(shell KCM= bash -c 'source scripts/lib/common.sh; echo $$KCM_VERSION')"
	@echo "  make e2e SCENARIO=02dep01_valid KCM=1.12.0-rc1      # any published version"
	@echo "  make e2e SCENARIO=02dep01_valid KCM=src-main        # a variant CI tests"
	@echo "  make e2e SCENARIO=02dep01_valid KCM=<sha> KCM_MODE=source"
	@echo
	@echo "Detail and examples for one target:  make <target> help"
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
#: Every environment that exists, not just the default one: which cluster is
#: up, what KCM is in it, and what to pass to reach it. Also lists working
#: directories whose clusters are gone.
#:
#: Vars: none -- it deliberately ignores the current selection.
status: ## Show which environments are built, and how to reuse them.
	./$(SCRIPTS)/status.sh

.PHONY: e2e
#: Everything in one go: build the environment, run the scenario, tear it
#: down. Around 7 minutes, most of it the build.
#:
#: Vars: SCENARIO (default 01_basic) and KCM -- see `make env-up help`.
#:
#:   make e2e SCENARIO=02dep01_valid
#:   make e2e SCENARIO=02dep01_valid KCM=1.12.0-rc1
#:   make e2e SCENARIO=01_basic KCM=my-branch KCM_MODE=source
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
#: Builds one k0s cluster and installs KCM into it. About 5 minutes. Stops
#: before any scenario runs. KCM deploys the services into this same cluster
#: (selfManagement), so there is no second cluster and no ClusterDeployment.
#:
#: Writes ./kcfg_k0rdent -- `export KUBECONFIG=kcfg_k0rdent` to poke at it.
#:
#: Vars: KCM -- what to install. A variant id from kcm-variants.yaml, a chart
#:       version, or a git ref with KCM_MODE=source. Recorded in
#:       .work/kcm-build.env, so no later target has to repeat it.
#:       OCI_URL is the registry (…/staging for a staging build), SRC_URL the
#:       repository to clone in source mode.
#:
#:   make env-up
#:   make env-up KCM=1.12.0-rc1
#:   make env-up KCM=480aad76 KCM_MODE=source
#:   make env-up KCM=my-branch KCM_MODE=source SRC_URL=https://github.com/me/kcm.git
env-up: ## Build the cluster and KCM, up to a verified child cluster.
	$(E2E) --env-up

.PHONY: scenario
#: Deploys the scenario's services through a MultiClusterService, verifies
#: them and removes them again. Needs `make env-up` first.
#:
#: Vars: SCENARIO. Nothing else: it runs against ./kcfg_k0rdent, and which
#:       KCM is there was recorded by env-up. A cluster you built yourself
#:       works too -- put its kubeconfig at ./kcfg_k0rdent.
#:
#:   make scenario SCENARIO=02dep01_valid
#:   make scenario SCENARIO=02dep01_valid RUN_ID=two   # a second environment
#:
#: Scenarios are not isolated from each other on a shared environment:
#: 02dep02_invalid breaks kyverno on purpose.
scenario: ## Run one scenario against an environment that is already up.
	$(E2E) --scenario-only

.PHONY: scenario-keep
#: Same as `scenario` but stops before removing the services, so you can
#: look at them. `make scenario-clean` removes them afterwards.
#:
#: Vars: as `scenario`.
#:
#:   make scenario-keep SCENARIO=02dep01_valid
#:   export KUBECONFIG=kcfg_k0rdent && kubectl get pods -A
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
#: Removes the containers, the network and ./kcfg_k0rdent, and the generated
#: manifests from .work. The KCM checkout and .bin are kept, since fetching
#: them again costs minutes. `make clean` is currently the same thing.
#:
#: Vars: none for the default environment; RUN_ID for one `make status` names.
#:
#:   make env-down
#:   make env-down RUN_ID=two
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
deps: ## Verify/install the required CLI tools into .bin.
	./$(SCRIPTS)/deps.sh

.PHONY: logs
#: Dumps controller logs, events and object state into ./logs<-RUN_ID>.
#: Run it before tearing a failed environment down.
#:
#: Vars: none for the default environment; RUN_ID for one `make status` names.
logs: ## Dump diagnostics from the current environment into ./logs.
	RUN_ID=$(RUN_ID) ./$(SCRIPTS)/collect_logs.sh

.PHONY: clean
#: The same as `env-down` today -- both call cleanup.sh with the same
#: arguments. Neither removes .work itself; `rm -rf .work` for that.
#:
#: Vars: none for the default environment; RUN_ID for one `make status` names.
clean: ## Tear the environment down (same as env-down).
	RUN_ID=$(RUN_ID) ./$(SCRIPTS)/cleanup.sh

endif
