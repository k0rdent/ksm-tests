# k0rdent-ksm-tests

End-to-end tests for **KSM** — the state-management layer of
[k0rdent KCM](https://github.com/k0rdent/kcm) that turns a `MultiClusterService`
into services running on a child cluster.

Everything is a shell script, so CI runs exactly what you run locally.

## What it tests

Each scenario builds a throwaway environment — one k0s cluster in Docker
running KCM — exercises one KSM behaviour and tears it down. Nothing is
provisioned: the `MultiClusterService` asks for `selfManagement`, so KCM
deploys the services into the cluster it runs in. No second cluster, no
`ClusterDeployment`, no cloud credentials, no cost.

| Scenario | Asserts |
|---|---|
| `01_basic` | one service reaches the child cluster and can be removed |
| `02dep01_valid` | a `dependsOn` chain deploys in order |
| `02dep02_invalid` | an invalid service stops the rollout: nothing behind it runs, nothing before it is rolled back |
| `03upg01_valid` | upgrading one service leaves the others untouched |
| `03upg02_invalid_atomic` | a failed atomic upgrade returns to the previous healthy state |
| `04mcs01_valid` | a dependent `MultiClusterService` waits for the one it depends on |
| `04mcs02_invalid_dependency` | a broken dependency holds the dependent back for good |
| `05chain01_no_chain` | with no `ServiceTemplateChain`, any version is reachable |
| `05chain02_boundary` | a chain offering nothing refuses every upgrade |
| `05chain03_direct_to_latest` | only what the chain lists is accepted |
| `05chain04_stepwise` | a multi-hop chain is walked, not skipped |

Each runs against two KCM builds: `src: main` and `release: 1.11.0`.

Install, `Management` reconcile and teardown are asserted too, because KSM
sits on them. Cloud provisioning is out of scope.

## Structure

```
test_scenarios/     one YAML per scenario -- the whole test definition
scripts/            the pipeline, one script per step
  lib/              shared helpers; services.sh reads the scenario files
  config/           KCM values, the Management object, the CI matrix
  tests/bash/       unit tests for the scripts, no cluster needed
.github/workflows/  e2e.yml picks what to run, e2e-scenario.yml runs it
```

## Running locally

### Create testing k0rdent cluster
~~~bash
# Create local k0s-in-docker cluster "k0rdent-<KCM>", deploy KCM
export KCM=1.11.0 # (required), can be any release tag of OCI_URL chart
# ... export k0rdent cluster kubeconfig to kcfg_k0rdent and kcfg_k0rdent_<KCM>
# export TEST_MODE=self (default); TODO later: "adopted, aws, gcp"
# export KCM_MODE=release (default); "source" - build and deploy kcm from SRC_URL git, KCM ref (tag, branch, sha)
./scripts/deploy_k0rdent.sh
~~~

### Run scenario
~~~bash
# TEST_MODE=self (default); "adopted" - run scenario in adopted mode (child)
# Run scenario on KUBECONFIG=kcfg_k0rdent
export SCENARIO=01_basic # (required) scenario id, fail for invalid, list available scenarios.
# export SCENARIO_KEEP=false (default) # optionally keep resources created by scenario 
./scripts/scenario_run.sh
# ./scripts/scenario_clean.sh # remove scenario objects (after SCENARIO_KEEP=true)
~~~

### List available testing scenarios
~~~bash
./scripts/get_scenarios.sh
# 01_basic        # one service reaches the child cluster and can be removed
# 02dep01_valid   # a `dependsOn` chain deploys in order
# ...
~~~

### List testing k0rdent clusters
~~~bash
# Every k0rdent-<KCM> cluster, and which one kcfg_k0rdent points at
./scripts/get_k0rdent_clusters.sh

# Switch the scenarios to another one
ln -sfn kcfg_k0rdent_1.12.0-rc1 kcfg_k0rdent
~~~

### Delete testing k0rdent cluster
~~~bash
export KCM=1.11.0 # (required)
./scripts/remove_k0rdent.sh # remove k0rdent-<KCM> in-docker cluster, remove kcfg_k0rdent and kcfg_k0rdent_<KCM>
~~~
