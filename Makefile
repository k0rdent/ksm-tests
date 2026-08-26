SHELL := /bin/bash

SCRIPTS := scripts

.PHONY: help
help: ## Show this help.
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: e2e
e2e: ## Run the full end-to-end test (build KCM, deploy, create/destroy a CAPD cluster).
	./$(SCRIPTS)/e2e_test.sh

.PHONY: e2e-keep
e2e-keep: ## Same as `e2e` but leaves the environment running for debugging.
	./$(SCRIPTS)/e2e_test.sh --keep

.PHONY: e2e-release
e2e-release: ## Run the e2e against the published KCM chart instead of a source build.
	KCM_SOURCE=release ./$(SCRIPTS)/e2e_test.sh

.PHONY: e2e-kserve
e2e-kserve: ## Run the e2e with the kserve service set instead of traefik.
	SERVICE_SET=kserve ./$(SCRIPTS)/e2e_test.sh

.PHONY: e2e-parallel
e2e-parallel: ## Run the source and release e2e side by side.
	@set -e; \
	RUN_ID=src KCM_SOURCE=source  ./$(SCRIPTS)/e2e_test.sh & src=$$!; \
	RUN_ID=rel KCM_SOURCE=release ./$(SCRIPTS)/e2e_test.sh & rel=$$!; \
	rc=0; wait $$src || rc=1; wait $$rel || rc=1; exit $$rc

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
	./$(SCRIPTS)/collect_logs.sh

.PHONY: clean
clean: ## Tear down containers, network and the working directory.
	./$(SCRIPTS)/cleanup.sh
