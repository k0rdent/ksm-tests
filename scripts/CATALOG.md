# Copied from k0rdent/catalog

These sit in `scripts/` under their original names, in catalog's own layout, so
the two repositories do not grow two different answers to the same provider
question. They are kept unedited on purpose: re-syncing is then a copy, not a
merge — and the layout is part of that, because they call each other as
`./scripts/<name>.sh` from the repository root.

| file | catalog |
|---|---|
| `check_test_mode.sh` | `scripts/check_test_mode.sh` |
| `check_aws_creds.sh` | `scripts/check_aws_creds.sh` |
| `check_azure_creds.sh` | `scripts/check_azure_creds.sh` |
| `check_gcp_creds.sh` | `scripts/check_gcp_creds.sh` |
| `setup_provider_credential.sh` | `scripts/setup_provider_credential.sh` |
| `export_cluster_template_names.sh` | `scripts/export_cluster_template_names.sh` |
| `list_cld_resources_aws.sh` | `scripts/list_cld_resources_aws.sh` |
| `list_cld_resources_azure.sh` | `scripts/list_cld_resources_azure.sh` |
| `list_cld_resources_gcp.sh` | `scripts/list_cld_resources_gcp.sh` |

`scripts/config/{aws,azure,gcp}-cld.yaml` come from catalog's `scripts/config/`
the same way, with one deliberate change: `aws-cld.yaml` asks for a `.medium`
control plane where catalog asks for `.small`. Catalog provisions a cluster to
demonstrate one application; a serial run puts a dozen helm installs and
uninstalls through the same control plane, and `.small` degrades under that
until the apiserver stops completing TLS handshakes.

**Run them from the repository root**, with `KUBECONFIG` pointing at the
management cluster and `TEST_MODE` and the provider variables in the
environment:

```bash
TEST_MODE=aws ./scripts/list_cld_resources_aws.sh
```

`scripts/steps/check_provider_creds.sh` and `scripts/steps/deploy_cloud_cluster.sh`
are what call them in the pipeline, and they `cd` to the root first so the call
works wherever it was started from.

`check_test_mode.sh` only knows catalog's modes — `aws`, `azure`, `gcp`,
`adopted` — so it is called for the provider modes alone; `self` is ours and
needs no credentials anyway.

What was **not** copied, and why:

- `deploy_cld.sh` / `remove_cld.sh` — their adopted half hardcodes one container
  name, network and port, so two environments on one host collide.
  `scripts/steps/deploy_adopted_cluster.sh` does the same job scoped per `$KCM`.
  The cloud half is small enough that `deploy_cloud_cluster.sh` follows it
  directly rather than wrapping it.
- `wait_for_cld.sh`, `wait_for_cluster_removal.sh`, `wait_for_servicetemplate.sh`,
  `wait_for_deployment.sh`, `retry.sh` — `scripts/lib/k8s.sh` already has these
  taking a kind, name, namespace and timeout, and they are used throughout.
  Copying the single-purpose versions would add a second way to wait.
