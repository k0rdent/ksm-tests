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

CI runs three legs in parallel: **src: main**, **release: 1.11.0** and
**release: 1.10.0**.

Both paths need the checkout, because it supplies the `Release` and template
manifests. Release mode pins it to the matching tag and refuses to run if the
chart version there disagrees with `KCM_RELEASE_VERSION`.

### The service test

After the child cluster is up, the run installs a `ServiceTemplate` per service
in `scripts/config/services.yaml`, deploys them all through a single
`MultiClusterService`, waits for the pods to be Ready *in the child cluster*,
then removes the MCS and verifies the workloads are gone.

The set mirrors k0rdent/catalog's `example` charts:

| Service | Chart | Namespace | Depends on |
|---|---|---|---|
| traefik | `traefik` 41.2.0 | `traefik` | – |
| cert-manager | `cert-manager` v1.20.2 | `cert-manager` | – |
| kserve-crd | `kserve-crd` v0.18.0 | `kserve` | cert-manager |
| kserve-resources | `kserve-resources` v0.18.0 | `kserve` | kserve-crd |

Two deliberate differences from catalog. It installs its own repackaged charts
from `oci://ghcr.io/k0rdent/catalog/charts`, which wrap the upstream ones — so
its MCS values are nested under the chart name. This project points at the
upstream repositories directly, to avoid depending on catalog releases, which
means the values in `services.yaml` are **one level flatter**. And catalog sets
`test_remove_multiclusterservice: false` for kserve; here removal is part of
what is being tested.

Swap the set with `SERVICES_FILE=/path/to/your.yaml`, or skip the whole thing
with `SKIP_SERVICE_TEST=true`.

### Parallel runs

Set `RUN_ID` and several runs coexist on one machine:

```bash
RUN_ID=src KCM_SOURCE=source  ./scripts/e2e_test.sh &
RUN_ID=rel KCM_SOURCE=release ./scripts/e2e_test.sh &
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

```bash
make e2e                      # full run, then clean up
make e2e-keep                 # leave the environment up for debugging
make e2e-release              # same, against the published chart
make e2e-parallel             # source and release side by side
```

To point at a specific KCM revision or a local checkout:

```bash
cp scripts/set_envs_template.sh set_envs.sh
$EDITOR set_envs.sh           # KCM_REF=... or KCM_SRC_DIR=...
source set_envs.sh
./scripts/e2e_test.sh
```

Individual steps are runnable on their own, in the order `e2e_test.sh` uses
them. After a run with `--keep`:

```bash
export KUBECONFIG=./kcfg_k0rdent
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
| `KCM_SOURCE` | `source` | `source` or `release` |
| `KCM_RELEASE_VERSION` | `1.11.0` | chart version for release mode |
| `KCM_REF` | mode-dependent | branch, tag or SHA to check out |
| `KCM_SRC_DIR` | – | use an existing checkout instead of cloning |
| `RUN_ID` | – | isolate this run from others; see above |
| `KCM_PROVIDERS` | CAPD, k0smotron, sveltos | providers KCM installs |
| `KCM_CLUSTER_TEMPLATES` | `docker-hosted-cp` | cluster templates to apply |
| `SERVICES_FILE` | `scripts/config/services.yaml` | services deployed via MCS |
| `SKIP_SERVICE_TEST` | – | `true` to skip the ServiceTemplate/MCS steps |
| `DOCKER_NETWORK` | `kind` | CAPD's network; the management cluster joins it |
| `WORKERS_NUMBER` | `1` | worker nodes in the child cluster |
| `CLD_TIMEOUT` | `1800` | seconds to wait for the ClusterDeployment |
| `DEBUG` | – | `true` for verbose helm output and pod describes |

Template versions (`docker-hosted-cp-1-0-15`, the `Release` name, …) are never
hardcoded — they are read from the charts in the KCM checkout.

## CI

* `e2e.yml` — the full run on `ubuntu-latest`; on PRs, on pushes touching
  `scripts/**`, nightly (needs repo variable `ENABLE_CRON=1`), or manually with
  a `kcm_ref` input. Diagnostics are uploaded as an artifact on failure.
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

Removal deletes the k0smotron etcd PVC explicitly: `docker-hosted-cp` exposes
`storage.etcd.autoDeletePVCs` but no template in chart 1.0.15 reads it, so the
PVC would outlive the cluster and the next run of the same name would boot on
the old etcd — complete with its stale, NotReady nodes.

## Not covered yet

KCM upgrades (N-1 → N), adopted and remote clusters, backup/restore, service
dependency graphs and template chains, and the cloud providers.
