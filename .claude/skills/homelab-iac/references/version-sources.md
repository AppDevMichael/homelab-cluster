# Where to verify each version (open the page; do not trust search snippets)

| Component | Pinned in | Verify at | Notes |
|---|---|---|---|
| OpenTofu | `mise.toml`, `tofu/versions.tf` | https://github.com/opentofu/opentofu/releases | Ignore "Pre-release". 1.12.x is the stable series (Sept 2026). |
| Ansible (community pkg) | `mise.toml` (`pipx:ansible`) | https://pypi.org/project/ansible/#history | Major N ↔ core version table in docs.ansible.com "Releases and maintenance". |
| kubectl | `mise.toml` | must equal the Kubernetes version inside the k3s pin | e.g. k3s v1.36.4+k3s1 → kubectl 1.36.4 |
| Helm | `mise.toml` | https://github.com/helm/helm/releases | v4 line since 2025. |
| kustomize | `mise.toml` | https://github.com/kubernetes-sigs/kustomize/releases | lint-only; prefix pin allowed. |
| restic | `mise.toml` | https://github.com/restic/restic/releases | |
| jq | `mise.toml` (laptop only; `scripts/restore-longhorn-volumes.sh`) | https://github.com/jqlang/jq/releases | tags are `jq-1.8.2` style; pin `1.8.2`. |
| k3s | `ansible/group_vars/all.yml` | https://github.com/k3s-io/k3s/releases | k3s marks new tags Pre-release for ~a week; wait for GA. Keep the SUC Plan channel on the same minor. |
| argo-cd chart | `gitops/bootstrap/templates/argocd.yaml` (Tofu derives it from there) | https://github.com/argoproj/argo-helm/releases (`argo-cd-X.Y.Z`) | Chart ≠ app version; app version is `appVersion` in Chart.yaml. |
| argocd-apps chart | `tofu/variables.tf` (`argocd_apps_chart_version`) | https://github.com/argoproj/argo-helm/releases (`argocd-apps-X.Y.Z`) | Seeds the root Application. |
| kube-prometheus-stack | `gitops/bootstrap/templates/monitoring.yaml` | https://github.com/prometheus-community/helm-charts/releases | Major bumps often change CRDs — read upgrade notes; `crds.upgradeJob` is on. |
| longhorn | `gitops/bootstrap/templates/longhorn.yaml` | https://github.com/longhorn/longhorn/releases | Chart version = app version. Upgrade one minor at a time (Longhorn requirement). |
| tailscale-operator | `gitops/bootstrap/templates/tailscale.yaml` | https://pkgs.tailscale.com/helmcharts/index.yaml | Chart version = Tailscale release; check tailscale.com/changelog for "stable". |
| kured | `gitops/bootstrap/templates/kured.yaml` | https://github.com/kubereboot/charts/releases | Chart ≠ app version. |
| system-upgrade-controller | `gitops/system-upgrade/kustomization.yaml` | https://github.com/rancher/system-upgrade-controller/releases | Two manifest URLs (crd.yaml + controller) — bump both. |
| hashicorp/helm, kubernetes providers | `tofu/versions.tf`, `.terraform.lock.hcl` | https://registry.opentofu.org | helm provider v3 changed syntax (`kubernetes = {}`, `set = [{}]`). |

Grafana community dashboards (`gnetId` + `revision` in `gitops/monitoring/values.yaml`) are pinned by
revision on grafana.com/dashboards; bump revision deliberately, they occasionally change datasource names.
