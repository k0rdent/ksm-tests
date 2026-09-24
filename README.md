# k0rdent KSM Tests

Run different testing `Scenarios` on any [k0rdent KCM](https://github.com/k0rdent/kcm)
version (source or release).

## Modes
- **Local** - run tests locally in your machine (docker) for troubleshooting.
- **CI** - run tests in GitHub CI workflows.

## Self-management testing
Tests are run in `self-management` mode to keep testing environment as simple as
possible, because it just requires a single testing k0s cluster.

Everything is a shell script, same scripts run in CI and locally.

## Testing Scenarios

Each scenario builds a throwaway environment — one k0s cluster in Docker
running KCM — exercises one KSM behaviour and tears it down. Nothing is
provisioned: the `MultiClusterService` asks for `selfManagement`, so KCM
deploys the services into the cluster it runs in. No second cluster, no
`ClusterDeployment`, no cloud credentials, no cost.

| Scenario | Asserts |
|---|---|
| `101_basic` | one service reaches the child cluster and can be removed |
| `201_svcdep` | a `dependsOn` chain deploys in order |
| `202_svcdep_invalid` | an invalid service stops the rollout: nothing behind it runs, nothing before it is rolled back |
| `301_upgrade` | upgrading one service leaves the others untouched |
| `302_upgrade_invalid_atomic` | a failed atomic upgrade returns to the previous healthy state |
| `401_mcsdep_valid` | a dependent `MultiClusterService` waits for the one it depends on |
| `402_mcsdep_invalid` | a broken dependency holds the dependent back for good |
| `501_no_chain` | with no `ServiceTemplateChain`, any version is reachable |
| `502_chain_boundary` | a chain offering nothing refuses every upgrade |
| `503_direct_chain` | only what the chain lists is accepted |
| `504_stepwise_chain` | a multi-hop chain is walked, not skipped |

Each runs against two KCM builds: `src: main` and `release: 1.12.0-rc.3`.

Install, `Management` reconcile and teardown are asserted too, because KSM
sits on them. Cloud provisioning is out of scope.

## Structure

```
test_scenarios/     one YAML per scenario -- the whole test definition
scripts/            the entry points below; everything you run by hand
  steps/            one script per pipeline step, 1:1 with the steps in CI
  utils/            subroutines the steps call; never run directly
  lib/              shared helpers; services.sh reads the scenario files
  config/           KCM values, the Management object, the CI matrix
  tests/bash/       unit tests for the scripts, no cluster needed
.github/workflows/  e2e.yml picks what to run, e2e-scenario.yml runs it
```

## Running locally

### Create testing k0rdent cluster
~~~bash
# Create local k0s-in-docker cluster "k0rdent-<KCM>", deploy KCM
export KCM=1.12.0-rc.3 # (required), can be any release tag of OCI_URL chart
# ... export k0rdent cluster kubeconfig to kcfg_k0rdent and kcfg_k0rdent_<KCM>
# export TEST_MODE=self (default); TODO later: "adopted, aws, gcp"
# export KCM_MODE=release (default); "source" - build and deploy kcm from SRC_URL git, KCM ref (tag, branch, sha)
./scripts/deploy_k0rdent.sh
~~~

### Run scenario
~~~bash
# TEST_MODE=self (default); "adopted" - run scenario in adopted mode (child)
# Run scenario on KUBECONFIG=kcfg_k0rdent
export SCENARIO=101_basic # (required) scenario id, fail for invalid, list available scenarios.
# export SCENARIO_KEEP=false (default) # optionally keep resources created by scenario 
./scripts/run_scenario.sh
# ./scripts/scenario_clean.sh # remove scenario objects (after SCENARIO_KEEP=true)
~~~

### List available testing scenarios
~~~bash
./scripts/scenarios.sh
# 101_basic        # one service reaches the child cluster and can be removed
# 201_svcdep   # a `dependsOn` chain deploys in order
# ...
~~~

### List testing k0rdent clusters
~~~bash
# Every k0rdent-<KCM> cluster, and which one kcfg_k0rdent points at
./scripts/k0rdent_clusters.sh

# Switch the scenarios to another one
ln -sfn kcfg_k0rdent_1.12.0-rc1 kcfg_k0rdent
~~~

### Delete testing k0rdent cluster
~~~bash
# remove test environment (cluster) by given index (see ./scripts/k0rdent_clusters.sh output)
./scripts/remove_k0rdent.sh 1
~~~
