# k0rdent-kcm-tests

Standalone end-to-end tests for [k0rdent KCM](https://github.com/K0rdent/kcm),
exercised on a throwaway cluster.

Everything is a shell script, so **CI runs exactly what you run locally** —
the same approach [k0rdent/catalog](https://github.com/k0rdent/catalog) uses.

## What it tests

| Area | Covered by |
|---|---|
| KCM installs, from source or from the release | `prepare_kcm.sh`, `push_kcm_artifacts.sh`, `deploy_kcm.sh` |
| Release and templates reconcile | `apply_release.sh`, `wait_for_templates.sh` |
| Management reaches Ready with the expected providers | `apply_management.sh`, `wait_for_management.sh` |
| ClusterDeployment provisions a working cluster | `deploy_cld.sh`, `check_child_cluster.sh` |
| Services reach the child cluster, in dependency order, and can be removed | `install_servicetemplate.sh`, `deploy_mcs.sh`, `remove_mcs.sh` |
| Deletion cleans up, including CAPD containers | `remove_cld.sh`, `wait_for_cluster_removal.sh` |
| Uninstall leaves nothing running | `remove_kcm.sh` |

The scenario is **CAPD** (`docker-hosted-cp`): a k0s management cluster in
Docker, child clusters as sibling containers. No cloud credentials, no cost.

KCM is installed with only three providers enabled — CAPD, k0smotron and
projectsveltos — instead of the eleven a default `Management` would pull in.
`Management` reaches Ready in about 2.5 minutes as a result.

A full run takes roughly 10 minutes with a warm KCM checkout, most of it
spent building the images and provisioning the child cluster.

### Two install paths

`KCM_SOURCE` picks what is under test:

| Mode | What happens |
|---|---|
| `source` (default) | Builds the controller and telemetry images from a KCM checkout, pushes the template charts to a throwaway local registry, and installs the chart from the source tree. Tests the code under review. |
| `release` | Installs `oci://ghcr.io/k0rdent/kcm/charts/kcm` at `KCM_RELEASE_VERSION`. No build, no registry, no Go or make needed. Tests what users actually get. |

CI is grouped **by scenario first, KCM variant second** — six jobs:

```
01_single_svc        / src: main | release: 1.11.0 | release: 1.10.0
02_depends_on_valid  / src: main | release: 1.11.0 | release: 1.10.0
```

Actions has no nested matrix, so `e2e.yml` holds the scenario dimension and
calls the reusable `e2e-scenario.yml`, which expands the versions underneath
it. A `discover` job builds both dimensions from `test_scenarios/*.yaml` and
`kcm-variants.yaml`, so neither adding a scenario nor adding a version needs a
workflow edit.

There is no way to fork a job mid-run and branch two "realities" off one
cluster — each combination gets its own runner and builds its own cluster from
scratch. That costs a KCM install per leg, but it is also what makes the legs
independent: a scenario that wedges its cluster cannot affect the others.

Both paths need the checkout, because it supplies the `Release` and template
manifests. Release mode pins it to the matching tag and refuses to run if the
chart version there disagrees with `KCM_RELEASE_VERSION`.

### Scenarios

A scenario is a file in **`test_scenarios/`** describing the services deployed
to the child cluster and how they depend on each other. After the child cluster
is up, the run installs a `ServiceTemplate` per service, deploys them all
through a single `MultiClusterService`, waits for the pods to be Ready *in the
child cluster*, then removes the MCS and verifies the workloads are gone.

| Scenario | What it exercises | Services |
|---|---|---|
| `01_single_svc` | the baseline MCS path, no dependencies | traefik |
| `02_depends_on_valid` | a valid `dependsOn` chain | cert-manager → kserve-crd → kserve-resources |

Adding one is a drop-in: put a file in `test_scenarios/`, and both `make
scenarios` and CI pick it up with no further edits.

```yaml
name: 02_depends_on_valid           # must match the filename
description: ...
knownFailures:                      # optional
  - kcm: rel-1-11-0
    reason: ...
services:
  - name: cert-manager
    chart: cert-manager
    version: 1.20.2
    repo: oci://ghcr.io/k0rdent/catalog/charts
    namespace: cert-manager
    waitForPods: cert-manager-
    values: |
      cert-manager:
        crds:
          enabled: true
  - name: kserve-crd
    dependsOn: cert-manager
    ...
```

`knownFailures` lists the KCM variants a scenario is known to fail on. CI still
runs and reports that leg, it just does not block the workflow. Delete the
entry once the defect is fixed upstream — a unit test checks every id there is
a real variant, so a typo cannot silently disable the marker.

Charts come from **k0rdent/catalog's registry** (`oci://ghcr.io/k0rdent/catalog/charts`),
the same artifacts catalog's own `example` charts reference. Those are thin
wrappers that declare the upstream chart as a dependency of the same name, so
values must be **nested one level under that name**. Flatten them and helm
ignores the lot without complaining — there is a unit test guarding this.

Skip the scenario steps entirely with `SKIP_SERVICE_TEST=true`.

### KCM variants

The KCM builds under test live in **`scripts/config/kcm-variants.yaml`** and are
picked with `KCM=<id>`:

| Id | What it installs |
|---|---|
| `src-main` | built from a `main` checkout |
| `rel-1-11-0` | published chart 1.11.0 |
| `rel-1-10-0` | published chart 1.10.0 |

The same file drives the CI matrix, so local runs and CI use the same ids —
which is also what makes `knownFailures` meaningful outside the workflow.
Setting `KCM_SOURCE` / `KCM_REF` / `KCM_RELEASE_VERSION` directly still wins,
for an ad-hoc version that is not a declared variant.

### Parallel runs

Set `RUN_ID` and several runs coexist on one machine:

```bash
make e2e-parallel KCM=src-main      # every scenario at once, own cluster each
```

or by hand, for arbitrary combinations:

```bash
RUN_ID=a SCENARIO=01_single_svc       KCM=src-main   ./scripts/e2e_test.sh &
RUN_ID=b SCENARIO=02_depends_on_valid KCM=rel-1-11-0 ./scripts/e2e_test.sh &
wait
```

Container names, host ports, the working directory, kubeconfigs, image tags,
the cluster name and the MCS selector label are all suffixed with it. Host
ports are picked from the first free one, so runs never fight over 6443 or
5001. Runs share the `kind` Docker network — that is CAPD's default and safe,
because the cluster names differ. They also share `.work/bin`, so the CLI
tools are downloaded once.

Without `RUN_ID` the plain names are used, so a single run is unchanged.

## Requirements

`docker`, `git`, `curl`, `tar`, `envsubst`, plus `make` and `go` for
`KCM_SOURCE=source`. Everything else (`kubectl`, `helm`, `yq`, `jq`) is
installed into `.work/bin` by `deps.sh`.

### macOS

Docker Desktop must be running, and `envsubst` comes from a keg-only formula:

```bash
brew install gettext && brew link --force gettext
```

The child cluster's API sits on a NodePort inside the Docker network, which a
macOS host cannot route to, so skip the checks that talk to it:

```bash
export SKIP_CHILD_API_CHECK=true
```

Everything up to and including the CAPI-side verification still runs. If you
have `TEST_MODE` exported for k0rdent/catalog (`aws`, `adopted`, …), `unset`
it — this project only knows `docker`.

## Running it

Pick a scenario and a KCM variant; `make scenarios` lists both.

```bash
make scenarios                                            # what is available
make e2e                                                  # 01_single_svc on src-main
make e2e SCENARIO=02_depends_on_valid KCM=rel-1-11-0      # one scenario, one version
make e2e-keep SCENARIO=02_depends_on_valid                # leave it up to poke at
```

### Reusing one environment across scenarios

Building the cluster and KCM is most of the wall clock, so for iterating
locally do it once and run every scenario through it:

```bash
make e2e-all KCM=src-main        # env-up, every scenario, env-down
```

or drive the phases yourself:

```bash
make env-up   KCM=src-main
make scenario SCENARIO=01_single_svc       KCM=src-main
make scenario SCENARIO=02_depends_on_valid KCM=src-main
make env-down KCM=src-main
```

**This is a debugging convenience, not a substitute for CI.** The scenarios
share a cluster, so one that leaves it wedged — `02_depends_on_valid` on
1.11.0 leaves a stuck MCS finalizer — taints whatever runs next. For a
trustworthy result use `make e2e` (its own environment per run) or CI.

To point at a specific KCM revision or a local checkout:

```bash
cp scripts/set_envs_template.sh set_envs.sh
$EDITOR set_envs.sh           # KCM_REF=... or KCM_SRC_DIR=...
source set_envs.sh
make e2e
```

Individual steps are runnable on their own, in the order `e2e_test.sh` uses
them. After a run with `--keep`:

```bash
export KUBECONFIG=./kcfg_k0rdent-local-src-main
kubectl get management kcm
kubectl get clusterdeployment -n kcm-system
```

## Other targets

```bash
make unit     # bash unit tests, no cluster needed
make lint     # shellcheck, plus actionlint if it is installed
make logs     # dump diagnostics into ./logs
make clean    # tear everything down
```

## Configuration

All defaults live in `scripts/lib/common.sh`; every one is an overridable
environment variable. The ones worth knowing:

| Variable | Default | Purpose |
|---|---|---|
| `KCM` | – | variant id (`src-main`, `rel-1-11-0`, …); sets the three below |
| `KCM_SOURCE` | `source` | `source` or `release` |
| `KCM_RELEASE_VERSION` | `1.11.0` | chart version for release mode |
| `KCM_REF` | mode-dependent | branch, tag or SHA to check out |
| `KCM_SRC_DIR` | – | use an existing checkout instead of cloning |
| `RUN_ID` | – | isolate this run from others; see above |
| `KCM_PROVIDERS` | CAPD, k0smotron, sveltos | providers KCM installs |
| `KCM_CLUSTER_TEMPLATES` | `docker-hosted-cp` | cluster templates to apply |
| `SCENARIO` | `01_single_svc` | scenario stem from `test_scenarios/` |
| `SERVICES_FILE` | derived from `SCENARIO` | override the scenario file outright |
| `SKIP_SERVICE_TEST` | – | `true` to skip the ServiceTemplate/MCS steps |
| `DOCKER_NETWORK` | `kind` | CAPD's network; the management cluster joins it |
| `WORKERS_NUMBER` | `1` | worker nodes in the child cluster |
| `CLD_TIMEOUT` | `1800` | seconds to wait for the ClusterDeployment |
| `DEBUG` | – | `true` for verbose helm output and pod describes |

Template versions (`docker-hosted-cp-1-0-15`, the `Release` name, …) are never
hardcoded — they are read from the charts in the KCM checkout.

## CI

* `e2e.yml` — discovers the scenarios and KCM variants, then calls
  `e2e-scenario.yml` once per scenario. Runs on PRs, on pushes touching
  `scripts/**` or `test_scenarios/**`, nightly (needs repo variable
  `ENABLE_CRON=1`), or manually with a `kcm_ref` input.
* `e2e-scenario.yml` — reusable; one scenario across every KCM variant, and
  where the `knownFailures` marker is applied. `continue-on-error` cannot be
  set on a job that calls a reusable workflow, which is why the marker lives
  here rather than in the caller. Diagnostics are uploaded on failure.
* `bash-unit-tests.yml`, `lint.yml` — fast checks on every change: shellcheck
  plus actionlint, because a workflow that fails to validate never starts a job
  and so produces no logs to debug.

## Design notes

KCM's own e2e suite (`test/e2e`, Ginkgo) cannot run outside its repository: it
shells out to `make test-apply`, embeds its matrix config with `go:embed`, and
assumes kind. This project deliberately avoids those targets and reuses only
KCM's stable build steps (`docker-build`, `templates-generate`, `helm-push`).

The chart is installed with `createManagement`, `createRelease` and
`createTemplates` all off, so the test controls exactly which Release,
Management and templates exist.

Two ordering details are load-bearing. `ClusterTemplate`s stay invalid until a
`Management` exists, so they are checked after it, not with the
`ProviderTemplate`s. And `Management.spec.core.kcm.config` has to repeat the
Helm values, or the HelmRelease reinstalls KCM from the published image and the
locally built one is never used.

The kserve teardown defect on KCM 1.11.0 is recorded in
`test_scenarios/02_depends_on_valid.yaml` under `knownFailures`, which is the
single source of truth for it: sveltos removes `kserve-crd` before uninstalling
`kserve-resources`, whose release still holds a `ClusterStorageContainer`, so
the uninstall fails with "ensure CRDs are installed first" and the MCS
finalizer never clears. 1.10.0 and main are unaffected.

Removal deletes the k0smotron etcd PVC explicitly: `docker-hosted-cp` exposes
`storage.etcd.autoDeletePVCs` but no template in chart 1.0.15 reads it, so the
PVC would outlive the cluster and the next run of the same name would boot on
the old etcd — complete with its stale, NotReady nodes.

## Not covered yet

KCM upgrades (N-1 → N), adopted and remote clusters, backup/restore, service
dependency graphs and template chains, and the cloud providers.
