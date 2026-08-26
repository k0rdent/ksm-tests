# k0rdent-kcm-tests

Standalone end-to-end tests for [k0rdent KCM](https://github.com/K0rdent/kcm),
built from source and exercised on a throwaway cluster.

Everything is a shell script, so **CI runs exactly what you run locally** —
the same approach [k0rdent/catalog](https://github.com/k0rdent/catalog) uses.

## What it tests

| Area | Covered by |
|---|---|
| KCM installs from a source build | `build_kcm.sh`, `push_kcm_artifacts.sh`, `deploy_kcm.sh` |
| Release and templates reconcile | `apply_release.sh`, `wait_for_templates.sh` |
| Management reaches Ready with the expected providers | `apply_management.sh`, `wait_for_management.sh` |
| ClusterDeployment provisions a working cluster | `deploy_cld.sh`, `check_child_cluster.sh` |
| Deletion cleans up, including CAPD containers | `remove_cld.sh`, `wait_for_cluster_removal.sh` |
| Uninstall leaves nothing running | `remove_kcm.sh` |

The scenario is **CAPD** (`docker-hosted-cp`): a k0s management cluster in
Docker, child clusters as sibling containers. No cloud credentials, no cost.

KCM is installed with only three providers enabled — CAPD, k0smotron and
projectsveltos — instead of the eleven a default `Management` would pull in.
`Management` reaches Ready in about 2.5 minutes as a result.

A full run takes roughly 10 minutes with a warm KCM checkout, most of it
spent building the images and provisioning the child cluster.

## Requirements

`docker`, `git`, `make`, `go`, `curl`, `tar`, `envsubst`. Everything else
(`kubectl`, `helm`, `yq`, `jq`) is installed into `.work/bin` by `deps.sh`.

Linux is the supported platform. On macOS the CAPI-side checks work, but the
child cluster's API is not reachable from the host — set
`SKIP_CHILD_API_CHECK=true`.

## Running it

```bash
make e2e                      # full run, then clean up
make e2e-keep                 # leave the environment up for debugging
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
make lint     # shellcheck
make logs     # dump diagnostics into ./logs
make clean    # tear everything down
```

## Configuration

All defaults live in `scripts/lib/common.sh`; every one is an overridable
environment variable. The ones worth knowing:

| Variable | Default | Purpose |
|---|---|---|
| `KCM_REF` | `main` | branch, tag or SHA to test |
| `KCM_SRC_DIR` | – | use an existing checkout instead of cloning |
| `KCM_PROVIDERS` | CAPD, k0smotron, sveltos | providers KCM installs |
| `KCM_CLUSTER_TEMPLATES` | `docker-hosted-cp` | cluster templates to apply |
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
* `bash-unit-tests.yml`, `lint-bash.yml` — fast checks on every change.

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

ServiceTemplates and MultiClusterService, KCM upgrades (N-1 → N), adopted and
remote clusters, backup/restore, and the cloud providers.
