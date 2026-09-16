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
| renovate chart | `gitops/bootstrap/templates/renovate.yaml` | https://docs.renovatebot.com/helm-charts/index.yaml — the INDEX, not GitHub tags (the index lags tags) | Renovate is excluded from bumping itself (renovate.json); update this pin by hand. |
| kube-prometheus-stack | `gitops/bootstrap/templates/monitoring.yaml` | https://github.com/prometheus-community/helm-charts/releases | Major bumps often change CRDs — read upgrade notes; `crds.upgradeJob` is on. |
| longhorn | `gitops/bootstrap/templates/longhorn.yaml` | https://github.com/longhorn/longhorn/releases | Chart version = app version. Upgrade one minor at a time (Longhorn requirement). |
| tailscale-operator | `gitops/bootstrap/templates/tailscale.yaml` | https://pkgs.tailscale.com/helmcharts/index.yaml | Chart version = Tailscale release; check tailscale.com/changelog for "stable". |
| cert-manager | `gitops/bootstrap/templates/cert-manager.yaml` | https://charts.jetstack.io/index.yaml | Chart version = app version with a `v` prefix (e.g. v1.21.2); GitHub releases page marks pre-releases. |
| cloudnative-pg | `gitops/bootstrap/templates/cloudnative-pg.yaml` | https://github.com/cloudnative-pg/charts/releases | Chart tag `cloudnative-pg-v0.x.y`; appVersion in the chart's Chart.yaml. |
| immich (chart) | `gitops/bootstrap/templates/immich.yaml` | https://github.com/immich-app/immich-charts/releases (OCI ghcr.io/immich-app/immich-charts) | Chart lags Immich; the Immich version is pinned separately. |
| immich (app) | `gitops/immich/values.yaml` `tag:` | https://github.com/immich-app/immich/releases | Skip `-rc.N` tags; check breaking-change notes (DB extension changes). |
| kured | `gitops/bootstrap/templates/kured.yaml` | https://github.com/kubereboot/charts/releases | Chart ≠ app version. |
| smartctl_exporter | `ansible/group_vars/all.yml` (`smartctl_exporter_version`, no `v`) | https://github.com/prometheus-community/smartctl_exporter/releases | Host binary from the linux-arm64 tarball (checksum from sha256sums.txt); the container image has no stable arm64 build. |
| system-upgrade-controller | `gitops/system-upgrade/kustomization.yaml` | https://github.com/rancher/system-upgrade-controller/releases | Two manifest URLs (crd.yaml + controller) — bump both. |
| hashicorp/helm, kubernetes providers | `tofu/versions.tf`, `.terraform.lock.hcl` | https://registry.opentofu.org | helm provider v3 changed syntax (`kubernetes = {}`, `set = [{}]`). |

Grafana community dashboards (`gnetId` + `revision` in `gitops/monitoring/values.yaml`) are pinned by
revision on grafana.com/dashboards; bump revision deliberately, they occasionally change datasource names.
