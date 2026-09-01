# CLAUDE.md — project context for Claude Code

This repo is a complete, GitOps-driven Kubernetes lab for **three Orange Pi 4 Pro boards (arm64, Armbian)**.
It was designed in a chat session and **has not yet been executed against real hardware**. Treat every
file as "carefully written, unvalidated" until the owner confirms otherwise.

## The owner's hard requirements (do not regress these)

- **Stable releases only.** No rc / beta / nightly / pre-release of anything. Verify a version is GA on its
  actual release page before pinning it; a search-result snippet is not enough (we got OpenTofu wrong once
  that way — 1.13 was pre-release text, 1.12.6 is the stable pin).
- **Exact pins** for tools (`mise.toml`) and charts (`gitops/bootstrap/templates/*.yaml`). Renovate bumps them.
- **No secrets in git.** Secrets are created by OpenTofu from `tfvars`/env and referenced by name from charts.
- **Zero-touch from a blank Armbian SD card** → root on NVMe → hardened → k3s HA → everything else via ArgoCD.
- **Everything on the Hetzner Storage Box is encrypted**, with one passphrase derived from the owner's SSH agent.
- **Full cluster recreate from backup** must stay a documented, scripted path.
- Tools are managed with **mise**; secrets/tokens come from a git-ignored `.env` that mise loads.
- `mise.toml` contains ONLY tools something in the repo invokes. The `ansible` community package is used
  (not `ansible-core` + galaxy) so there is no collection-install step.

## Architecture in one paragraph

Ansible (`ansible/`) takes fresh boards from DHCP + default root password to a hardened, static-IP, NVMe-rooted,
Tailscale-joined 3-server k3s cluster (embedded etcd, all nodes schedulable) with restic backups of etcd to the
Storage Box. OpenTofu (`tofu/`) runs once: installs ArgoCD, creates the few Secrets git can't hold, and seeds the
root Application; its state lives **in the cluster** (kubernetes backend, `kube-system/tfstate-default-opi-k8s`,
encrypted with the backup key). ArgoCD reconciles everything else from `gitops/` using an app-of-apps Helm chart
(`gitops/bootstrap`): ArgoCD itself, Longhorn (replicated + LUKS-encrypted storage, SMB backups to the Storage Box),
kube-prometheus-stack (Grafana dashboards, SBC alerts), Tailscale operator (optional), system-upgrade-controller
(k3s patch auto-upgrades), and kured (drained rolling reboots after OS updates).

## Layout

```
mise.toml                 exact CLI tool pins        .env.example → .env (git-ignored, loaded by mise)
Makefile                  the entry points (make help)
CLAUDE.md / README.md     this file / user docs (README has the full runbooks — keep it in sync)
renovate.json             version bumps: argocd manager for charts, regex managers for k3s/SUC/tofu, mise manager
scripts/
  backup-key.sh           BACKUP_KEY = sha256(ssh-keygen -Y sign of a fixed message)  — Ed25519/RSA only
                          signs with $BACKUP_SSH_PUBKEY (set in .env) or ~/.ssh/id_ed25519.pub; pick once, never change
  backup-config.sh        restic (SFTP:23) of tfvars/lockfile/kubeconfigs/.env/storagebox key  ← laptop side
  restore-longhorn-volumes.sh   DR: recreate Volume + PV + PVC from latest Longhorn backups
  prepare-sd.sh           optional Linux-only: seed SSH key onto a fresh SD (avoids root/1234 login)
ansible/
  site.yml                plays in order: firstboot(+nvme) → common,tailscale,hardening,updates → k3s init → k3s join → backup → kubeconfig
  upgrade-os.yml          manual rolling apt full-upgrade with drain/reboot/uncordon
  inventory/hosts.yml     ansible_host = target static IP, firstboot_ip = first-boot DHCP IP (remove after)
  group_vars/all.yml      ALL tunables: versions, CIDRs, static IP, NVMe, hardening, updates, backups
  roles/
    firstboot   kill Armbian wizard, ssh key, random root pw (→ ansible/secrets/), locale, netplan static IP
    nvme        partition/format/rsync root to NVMe; /boot stays on SD (bind mount); SD OS kept as fallback
    common      swap off (zram), cgroup boot args, sysctls, modules (dm_crypt, iscsi_tcp), packages
    tailscale   apt repo, `tailscale up --ssh`, auto-update, records tailscale_ip/tailscale_dns facts
    hardening   ops user + keys, sshd drop-in, nftables (default-drop, k3s-aware), sysctls, fail2ban, journald
    updates     unattended-upgrades (security pockets), needrestart, reboot-required flag for kured
    k3s         config.yaml (tls-san incl. tailscale, PSA baseline, audit log, metrics bind), install, wait Ready
    backup      restic → Storage Box: systemd timer per node, etcd snapshot + /etc/rancher/k3s, prune on init node
tofu/
  backend.tf    kubernetes backend + OpenTofu state encryption (pbkdf2 from var.backup_key, enforced)
  argocd.tf     helm_release argo-cd (lifecycle ignore_changes: ArgoCD self-manages afterwards) + root app
  secrets.tf    ns monitoring (+grafana-admin), ns tailscale (+operator-oauth) — PSA privileged labels
  longhorn.tf   ns longhorn-system (+longhorn-crypto LUKS key, +longhorn-backup-cifs)
  variables.tf  git_repo_url, backup_key, storagebox_*, tailscale_oauth_*, grafana_admin_password
gitops/
  bootstrap/    Helm chart of Applications. values.yaml: repo url/revision + toggles (tailscale, monitoring)
                templates/: root, argocd(-10), longhorn(-3), tailscale(-5), monitoring(0), kured(5), system-upgrade(5)
                _helpers.tpl: shared syncPolicy (automated prune+selfHeal, ServerSideApply, retry)
  argocd/       values (insecure behind ingress, dex/notifications/appset off, small resources)
  longhorn/     values (defaultBackupStore cifs://…, nodeDownPodDeletionPolicy, preUpgradeChecker off) + manifests/
                (StorageClasses: longhorn-encrypted=default with LUKS secret refs, longhorn; RecurringJobs)
  monitoring/   kube-prometheus-stack values (existingSecret grafana-admin, longhorn-encrypted PVCs,
                k3s control-plane endpoints = node IPs) + manifests/sbc-alerts.yaml (temp/disk/mem/longhorn)
  tailscale/    operator values (oauth from secret, apiServerProxy on) + manifests/ (Ingress class tailscale
                for grafana, argocd, longhorn UI)
  system-upgrade/  kustomization pulling SUC v0.18.0 release manifests + Plan (channel v1.36, concurrency 1)
  kured/        values (03:00–05:00 UTC window, lock, ServiceMonitor) + manifests/namespace (privileged)
```

## Pinned versions (all GA, verified 2026-09-01)

k3s v1.36.4+k3s1 · argo-cd chart 10.4.2 · kube-prometheus-stack 88.3.0 · longhorn 1.12.0 ·
tailscale-operator 1.102.3 · kured chart 6.0.0 · system-upgrade-controller v0.18.0 ·
OpenTofu 1.12.6 · Ansible 13.x community package (= core 2.20 + collections) · kubectl 1.36.4 · Helm 4.2.4 · restic 0.19.1 · jq 1.8.2 ·
hashicorp/helm provider ~>3.2 (v3 syntax: `kubernetes = {}`, `set = [{}]`) · hashicorp/kubernetes ~>2.38

## Key design decisions (and why)

- 3 servers, no agents: etcd quorum + all boards schedulable. Losing 1 node is fine, losing 2 is not.
- Tailscale is for *access* (SSH, kubectl, UIs); pod traffic stays on LAN flannel. Node Tailscale IPs and
  MagicDNS names are in the API cert. Two kubeconfigs are written: `kubeconfig` (LAN), `kubeconfig-tailscale`.
- nftables never `flush ruleset` (would wipe kube-proxy). Allowed in: lo, established, ICMP, pod/svc CIDRs,
  CNI ifaces, other node IPs, tailscale0 + udp/41641, DHCP, LAN→22/80/443/6443. forward/output untouched.
- PSA `baseline` enforced cluster-wide; kube-system exempt; monitoring/tailscale/longhorn-system/kured/
  system-upgrade namespaces are labeled `privileged` explicitly.
- Unattended-upgrades applies **security pockets only**; Armbian repo (kernel/u-boot) is manual via
  `make os-upgrade` unless `updates_include_armbian_repo: true`. apt never reboots; kured does, drained, windowed.
- Backup key: `ssh-keygen -Y sign` of a fixed message with an Ed25519 key in the agent → deterministic →
  sha256. Used for restic (nodes + laptop), Longhorn LUKS, Tofu state encryption. Owner must also store it in
  a password manager. Changing the message/namespace in `scripts/backup-key.sh` changes the key — don't.
- Longhorn backups of encrypted volumes are encrypted; so nothing on the Storage Box is plaintext.
  SMB (Longhorn) needs the Storage Box *password*; SFTP (restic) uses a generated key in ansible/secrets/.
- DR order: restore laptop secrets from restic → `make bootstrap` → set monitoring.enabled=false in
  gitops/bootstrap/values.yaml → `make argocd` → wait for backupvolumes → `make restore-volumes` → re-enable.
- ArgoCD manages itself; Tofu's helm_release has `ignore_changes = [version, values]`. Bump ArgoCD in git,
  mirror the version in tofu/variables.tf so a fresh bootstrap matches.

## Things to know before running anything

- `make help` lists targets. Order: `make deps` → edit .env/hosts.yml/group_vars → `make key` (save it) →
  `make bootstrap` → `make argocd`. After first bootstrap: set `ansible_user: ops` and delete `firstboot_ip`.
- `make lint` = ansible-lint, tofu fmt/validate, helm lint bootstrap chart, kustomize build system-upgrade.
- Owner's laptop location is Ireland (locale en_IE.UTF-8 default; timezone left UTC — ask before changing).
- Never expose the Longhorn UI on the LAN (no auth). Tailnet ingress only.
- `sshpass` is a host prerequisite (first-boot password login + Storage Box key install).

## Known untested / fragile spots (highest risk first)

1. `roles/nvme`: rsync-to-NVMe + bind-mounting SD `/boot`; `rootdev=` edit in armbianEnv.txt. Verify on one board.
2. `roles/firstboot`: relies on Armbian allowing non-interactive root SSH with default password `1234`.
   Some builds force a password change → use `scripts/prepare-sd.sh`. Netplan interface name comes from facts.
3. Longhorn CIFS target to Hetzner (SMB3 required; may need `vers=3.0` mount option — check longhorn-manager logs).
4. `scripts/restore-longhorn-volumes.sh`: mimics Longhorn UI "create PV/PVC"; field names from BackupVolume
   status (`KubernetesStatus`, `lastBackupName`) need confirming against 1.12. `DRY_RUN=1` first.
5. kube-prometheus-stack 88.x / longhorn 1.12 / kured 6 values keys were written from memory of chart schemas;
   run `helm template` with the values files to catch renamed keys before first sync.
6. Helm provider v3 syntax in tofu/ and the `encryption {}` block: run `tofu validate` (needs network).
7. system-upgrade Plan: `channel: v1.36` chosen to match the Ansible pin; do not use `stable` (could be lower).

## Agreed next batch (not done yet)

1. Alertmanager receiver (Discord/Telegram/email) + kured `notifyUrl` via Secret — alerts currently go nowhere.
2. Dead man's switch: Alertmanager `Watchdog` → healthchecks.io.
3. ArgoCD metrics ServiceMonitor + alert on apps not Synced/Healthy.
4. Turn off LAN (plain-HTTP) ingresses for ArgoCD/Grafana once Tailscale ingress works.
5. `make check`: nodes Ready, apps Synced, backup target available, restic snapshot <24h, no degraded volumes.
6. CI workflow running `make lint` on PRs (so Renovate PRs are validated).
Later: Longhorn System Backup, Loki+Alloy logs, cert-manager/local DNS, Trivy, NetworkPolicies, RAM check
(confirm Orange Pi 4 Pro memory; trim limits if 4 GB), UPS.

## Conventions when editing

- Keep README.md runbooks in sync with any behaviour change; keep the version table accurate.
- YAML in Ansible: FQCN modules, `no_log` on anything touching secrets, idempotent (re-runs must be no-ops).
- New ArgoCD app = new `gitops/bootstrap/templates/<name>.yaml` (copy monitoring.yaml, multi-source: chart +
  `$values` ref + optional manifests path) + `gitops/<name>/values.yaml`. Use the shared syncPolicy helper.
  If it needs privileged pods, ship a Namespace manifest with the PSA label (sync-wave -1) or create it in Tofu.
- Anything needing a secret: create it in Tofu, reference by name from values. Never put values in git.
- Validate YAML (`python -c "import yaml…"` or `yq`), `bash -n` scripts, and run `make lint` before finishing.
