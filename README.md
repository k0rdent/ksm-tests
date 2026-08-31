# k0rdent-ksm-tests

End-to-end tests for **KSM** — the state-management layer of
[k0rdent KCM](https://github.com/K0rdent/kcm) that turns a `MultiClusterService`
into services running on a child cluster.

Everything is a shell script, so CI runs exactly what you run locally.

## What it tests

Each scenario builds a throwaway environment — two k0s clusters in Docker, one
running KCM and one it adopts — exercises one KSM behaviour and tears it all
down. Nothing is provisioned through CAPI: KCM is handed the second cluster's
kubeconfig, which is what the `adopted-cluster` template is for. No cloud
credentials, no cost.

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

Each runs against three KCM builds: `src: main`, `release: 1.11.0` and
`release: 1.10.0`.

Install, `Management` reconcile, `ClusterDeployment` and teardown are asserted
too, because KSM sits on them. Cloud provisioning is out of scope.

## Structure

```
test_scenarios/     one YAML per scenario -- the whole test definition
scripts/            the pipeline, one script per step
  lib/              shared helpers; services.sh reads the scenario files
  config/           cluster template, KCM values, KCM variants
  tests/bash/       unit tests for the scripts, no cluster needed
.github/workflows/  e2e.yml picks what to run, e2e-scenario.yml runs it
```

## Running locally

```bash
make scenarios                                       # what is available
make env-up        KCM=rel-1-11-0                         # both clusters + KCM, ~7 min
make scenario      SCENARIO=02dep01_valid KCM=rel-1-11-0  # deploy, verify, remove
make scenario-keep SCENARIO=02dep01_valid KCM=rel-1-11-0  # deploy + verify, leave services running
make scenario-clean SCENARIO=02dep01_valid KCM=rel-1-11-0 # remove services from a kept scenario
make env-down      KCM=rel-1-11-0
```

Needs `docker`, `git`, `curl`, `tar`, `envsubst`, plus `go` and `make` for
`KCM=src-main`. The rest lands in `.work/bin` via `make deps`.

A full run — build, scenario, teardown — takes 9 to 11 minutes depending on
the scenario.

`scenario-keep` / `scenario-clean` let you inspect the deployed services
between runs — deploy once, poke around, then clean up when you are done.

Sharing one environment across scenarios is a debugging convenience, not a
substitute for CI. Scenarios are genuinely not isolated that way:
`02dep02_invalid` breaks cert-manager on purpose, so everything after it that
needs cert-manager fails too.

The adopted cluster publishes its API on the host, so the checks that read it —
helm releases, pod UIDs, workloads — work on macOS as they do on Linux. KCM
reaches the same cluster by its address on the docker network, which is why
there are two kubeconfigs: `kcfg_adopted*` for you, and one in a Secret for KCM.

## Adding a scenario

Drop a file in `test_scenarios/`. Nothing else needs editing: `make scenarios`
and CI both discover it, and CI works out which scripts it exercises from the
fields it uses.

```yaml
name: 06thing_valid          # must match the filename
group: Some area             # heading in `make scenarios`
description: What it proves.

services:
  - name: traefik
    chart: traefik
    version: 41.2.0
    repo: oci://ghcr.io/k0rdent/catalog/charts
    namespace: traefik
    waitForPods: traefik-    # optional
    dependsOn: cert-manager  # optional
    values: |                # optional
      traefik:
        ...
```

Charts come from **k0rdent/catalog's registry**. Those are wrappers declaring
the upstream chart as a dependency of the same name, so values must be nested
one level under that name — flatten them and helm ignores them silently.

Optional blocks, each switching on extra checks:

| Block | Asserts |
|---|---|
| `expect: {failed, blocked, deployed, graceSeconds}` | the rollout stops at `failed`, `blocked` never installs, `deployed` survives |
| `upgrade: {services, expect: {rolledOut, untouched, rolledBackTo}}` | only `rolledOut` moves; `untouched` keeps its chart *and* its pod UIDs |
| `templateChain` + `upgrade.steps` | each step is `applied` or `rejected` as the chain dictates; `viaVersions` must appear in helm history |
| `helmOptions: {atomic: true}` | passed to the provider from the first deploy on |
| `multiClusterServices` | replaces `services:` when a scenario needs more than one MCS |

Run `make unit` and `make lint` before pushing; neither needs a cluster.

### Known failures

A scenario records the KCM versions it is known to fail on. The step still runs
and reports, but as a warning rather than a red job:

```yaml
knownFailures:
  - kcm: rel-1-10-0
    step: Upgrade services                      # which step must fail
    match: did not roll back to a healthy state # and with what in its output
    timeout: 300                                # shorten the waits on this leg
    reason: ...
```

The marker is deliberately narrow — the failure has to happen in that step
*and* print that string — so it cannot hide an unrelated regression. Delete the
entry once the defect is fixed upstream.

Two are recorded today, both upstream defects rather than test bugs:
`03upg02_invalid_atomic.yaml` (1.10.0 removes the release instead of rolling
back) and `05chain04_stepwise.yaml` (a chain constrains which versions may be
reached, but not the route taken).

## CI

A pull request runs only what the change can reach, against `rel-1-11-0`: a
published chart cannot move underneath a PR, so a red leg means the change
broke something.

| Changed | Runs |
|---|---|
| a scenario file | that scenario |
| `upgrade_chain.sh`, `upgrade_services.sh`, `deploy_mcs_group.sh`, `verify_mcs_failure.sh` | the scenarios using that feature |
| `.github/workflows/**` | one scenario per feature area |
| `scripts/config/**` | `01_basic` |
| anything else in `scripts/**` | every scenario |
| `prepare_kcm.sh`, `push_kcm_artifacts.sh`, `deploy_registry.sh` | `01_basic`, against `src: main` |
| only docs | nothing |

Label a PR `ci:full` to run everything anyway.

**The full matrix runs on `main` and nightly**, and needs to: both races found
in the upgrade scenarios showed up only on `src: main`. Nightly needs the repo
variable `ENABLE_CRON=1`.

Pushes trigger CI only on `main`; elsewhere the pull request does, because a
branch with an open PR fires both events and the cancelled duplicate shows on
the PR as a failed check.
