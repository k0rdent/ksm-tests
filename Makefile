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

.PHONY: unit
unit: ## Run the bash unit tests (no cluster required).
	./$(SCRIPTS)/tests/bash/run.sh

.PHONY: lint
lint: ## Run shellcheck over every shell script.
	shellcheck $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh $(SCRIPTS)/tests/bash/*.sh

.PHONY: deps
deps: ## Verify/install the required CLI tools into .work/bin.
	./$(SCRIPTS)/deps.sh

.PHONY: logs
logs: ## Dump diagnostics from the current environment into ./logs.
	./$(SCRIPTS)/collect_logs.sh

.PHONY: clean
clean: ## Tear down containers, network and the working directory.
	./$(SCRIPTS)/cleanup.sh
