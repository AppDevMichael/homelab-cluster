# CLAUDE.md — project context for Claude Code

This repo is the owner's **home Kubernetes cluster** on **three Orange Pi 4 Pro boards (arm64, Armbian)** — GitOps-driven,
used for learning but also running **real workloads**: treat it as production (canary one node first, no casual reboots,
no disruptive experiments on the live cluster).
Both halves have been **executed and verified on the real boards**: Ansible (`make bootstrap`, 2026-09-02) and OpenTofu +
ArgoCD (`make argocd`, 2026-09-03: all six Applications Synced/Healthy, Grafana/Prometheus on LUKS Longhorn volumes).

## The owner's hard requirements (do not regress these)

- **Stable releases only.** No rc / beta / nightly / pre-release of anything. (Exception the owner accepted: Armbian
  has no stable build for the Orange Pi 4 Pro, so the OS/kernel is a pinned `trunk` nightly — see Hardware facts.) Verify a version is GA on its
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
kernel/                   custom Armbian vendor kernel (see kernel/README.md): userpatches/extensions/{k8s-storage,headless-lowpower}.sh,
                          userpatches/VERSION (26.08.0-k8s.N — bump per rebuild), debs/ (output, git-ignored), build/ (armbian/build, ignored)
scripts/
  build-kernel.sh         `make kernel`: armbian/build @ pinned commit 8b778f3d8 (boards' image commit), Docker, → kernel/debs/
  backup-key.sh           BACKUP_KEY = sha256(ssh-keygen -Y sign of a fixed message)  — Ed25519/RSA only
                          signs with $BACKUP_SSH_PUBKEY (set in .env) or ~/.ssh/id_ed25519.pub; pick once, never change
  backup-config.sh        restic (SFTP:23) of tfvars/lockfile/kubeconfigs/.env/storagebox key  ← laptop side
  restore-longhorn-volumes.sh   DR: recreate Volume + PV + PVC from latest Longhorn backups
  prepare-sd.sh           optional Linux-only: seed SSH key onto a fresh SD (avoids root/1234 login)
ansible/
  site.yml                plays in order: firstboot(+nvme) → kernel,common,tailscale,hardening,updates → k3s init → k3s join → backup → kubeconfig
                          roles/hardening ends with set_fact ansible_user=hardening_admin_user (root SSH is off by then); firstboot uses root only when firstboot_ip is set
  upgrade-os.yml          manual rolling apt full-upgrade with drain/reboot/uncordon
  kernel.yml              rolling custom-kernel install (`make kernel-install [LIMIT=opi-2]`), drains only if k3s present
  spi-boot.yml            `make spi-boot [LIMIT=opi-2]`: apply roles/nvme/tasks/spi.yml one node at a time (then remove SD cards)
  inventory/hosts.yml     ansible_host = target static IP, firstboot_ip = first-boot DHCP IP (remove after)
  group_vars/all.yml      ALL tunables: versions, CIDRs, static IP, NVMe, hardening, updates, backups
  roles/
    firstboot   kill Armbian wizard, ssh key, random root pw (→ ansible/secrets/), locale, netplan static IP
    nvme        partition/format/rsync root to NVMe; /boot on SD (bind mount) as stage 1; spi.yml (nvme_spi_boot, default on):
                u-boot → SPI NOR (write_uboot_platform_mtd, only if blobs differ), /boot → NVMe, SD dropped from fstab → pull the card
    kernel      stage kernel/debs/*.deb, apt install + hold; drain → reboot → uncordon ONLY when the running kernel lacks
                dm-crypt (a no-op run touches nothing); verify modules; lowpower.yml blacklists wifi/BT/video + masks services
    common      swap off (zram), cgroup boot args, sysctls, modules (dm_crypt, iscsi_tcp), packages
    tailscale   apt repo, `tailscale up --ssh`, auto-update, records tailscale_ip/tailscale_dns facts
    hardening   ops user + keys, sshd drop-in, nftables (default-drop, k3s-aware), sysctls, fail2ban, journald
    updates     unattended-upgrades (security pockets), needrestart, reboot-required flag for kured
    k3s         config.yaml (tls-san incl. tailscale, PSA baseline, audit log, metrics bind), install, wait Ready
    backup      restic → Storage Box: systemd timer per node, etcd snapshot + /etc/rancher/k3s, prune on init node;
                /etc/ssh/ssh_config.d/50-storagebox.conf carries port/key/pinned host key so plain `restic` works on a node
tofu/
  backend.tf    kubernetes backend + OpenTofu state encryption (pbkdf2 from var.backup_key, enforced)
  argocd.tf     helm_release argo-cd (lifecycle ignore_changes: ArgoCD self-manages afterwards) + root app as a 2nd
                helm_release of argo/argocd-apps 2.0.5 (CRDs must exist before the Application can be validated)
  secrets.tf    ns monitoring (+grafana-admin), ns tailscale (+operator-oauth) — PSA privileged labels
  longhorn.tf   ns longhorn-system (+longhorn-crypto LUKS key, +longhorn-backup-s3: endpoint + bucket-scoped key pair)
  variables.tf  git_repo_url(+_ssh_private_key_file), backup_key, longhorn_s3_*, tailscale_oauth_*, grafana_admin_password
  providers.tf  no config_path: kubeconfig comes from KUBE_CONFIG_PATH (mise → kubeconfig-tailscale); same for the backend
gitops/
  bootstrap/    Helm chart of Applications. values.yaml: repo url/revision + toggles (tailscale, monitoring)
                templates/: root, argocd(-10), longhorn(-3), tailscale(-5), monitoring(0), kured(5), system-upgrade(5)
                _helpers.tpl: shared syncPolicy (automated prune+selfHeal, ServerSideApply, retry)
  argocd/       values (insecure behind ingress, dex/notifications/appset off, small resources)
  longhorn/     values (defaultBackupStore s3://<bucket>@<region>/opi-k8s/longhorn/ — B2; nodeDownPodDeletionPolicy, preUpgradeChecker off) + manifests/
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
tailscale-operator 1.102.3 · kured chart 6.0.0 · argocd-apps chart 2.0.5 · system-upgrade-controller v0.18.0 ·
OpenTofu 1.12.6 · Ansible 14.3.1 community package (= core 2.21.3 + collections) · kubectl 1.36.4 · Helm 4.2.4 · restic 0.19.1 · jq 1.8.2 ·
hashicorp/helm provider ~>3.2 (v3 syntax: `kubernetes = {}`, `set = [{}]`) · hashicorp/kubernetes ~>2.38

## Key design decisions (and why)

- 3 servers, no agents: etcd quorum + all boards schedulable. Losing 1 node is fine, losing 2 is not.
- Tailscale is for *access* (SSH, kubectl, UIs); pod traffic stays on LAN flannel. Node Tailscale IPs and
  MagicDNS names are in the API cert. Two kubeconfigs are written: `kubeconfig` (LAN), `kubeconfig-tailscale`.
  **Default is the Tailscale one** (mise KUBECONFIG, Tofu backend + providers): the LAN firewall only admits fixed admin
  IPs and the laptop's DHCP lease moved once. Ansible still uses LAN `ansible_host` (it doubles as the node's cluster IP).
- nftables never `flush ruleset` (would wipe kube-proxy). Allowed in: lo, established, ICMP, pod/svc CIDRs,
  CNI ifaces, other node IPs, tailscale0 + udp/41641, DHCP, LAN→22/80/443/6443. forward/output untouched.
- PSA `baseline` enforced cluster-wide; kube-system exempt; monitoring/tailscale/longhorn-system/kured/
  system-upgrade namespaces are labeled `privileged` explicitly.
- Unattended-upgrades applies **security pockets only**; Armbian repo (kernel/u-boot) is manual via
  `make os-upgrade` unless `updates_include_armbian_repo: true`. apt never reboots; kured does, drained, windowed.
- Backup key: `ssh-keygen -Y sign` of a fixed message with an Ed25519 key in the agent → deterministic →
  sha256. Used for restic (nodes + laptop), Longhorn LUKS, Tofu state encryption. Owner must also store it in
  a password manager. Changing the message/namespace in `scripts/backup-key.sh` changes the key — don't.
- Longhorn backups of encrypted volumes are encrypted; nothing off-site is plaintext. Two destinations: restic → Storage Box
  over SFTP:23 (generated key in ansible/secrets/, repo path relative `opi-k8s/restic`); Longhorn → an S3 bucket (B2) because
  the Storage Box only offers SFTP/SMB and the owner's ISP blocks SMB. Object Lock rejected (breaks Longhorn pruning);
  use bucket versioning + "keep prior versions 30 days" and bucket-scoped keys instead.
- DR order: restore laptop secrets from restic → `make bootstrap` → set monitoring.enabled=false in
  gitops/bootstrap/values.yaml → `make argocd` → wait for backupvolumes → `make restore-volumes` → re-enable.
- ArgoCD manages itself; Tofu's helm_release has `ignore_changes = [version, values]`. Bump ArgoCD in git,
  mirror the version in tofu/variables.tf so a fresh bootstrap matches.

## Things to know before running anything

- `make help` lists targets. The backup key is derived only inside recipes that need it (NEED_KEY macro). Order: `make deps` → edit .env/hosts.yml/group_vars → `make key` (save it) →
  `make kernel` (Docker, ~1 h) → `make bootstrap` → `make argocd`. After first bootstrap: delete `firstboot_ip` (the user switch
  to `ops` is a set_fact at the end of roles/hardening; inventory `ansible_user` is `ops` from the start).
- `make lint` = ansible-lint, tofu fmt/validate, helm lint bootstrap chart, kustomize build system-upgrade.
- Owner's laptop location is Ireland (locale en_IE.UTF-8 default; timezone left UTC — ask before changing).
- Never expose the Longhorn UI on the LAN (no auth). Tailnet ingress only.
- `sshpass` is a host prerequisite (first-boot password login + Storage Box key install). Docker for `make kernel`.
- Owner wants the boards on Debian trixie with the vendor kernel branch (no distro/branch switching).

## Hardware facts (verified on real boards 2026-09-01)

- Orange Pi 4 Pro = Allwinner A733 (family `sun60iw2`), 8 cores, **12 GB RAM**, NVMe present. Armbian ships it
  only as a `.csc` community board → **nightly images only** (`26.11.0-trunk.x`, Debian 13). No stable OS exists.
- Vendor kernel `6.6.98-vendor-sun60iw2` (upstream config `linux-sun60iw2-vendor.config`) has **no device-mapper
  (`CONFIG_MD`), no dm-crypt, no iSCSI, no XTS, no CIFS**. Decision: **custom kernel** (`make kernel`, `kernel/`), same
  source + Armbian commit, config only. Owner also wants HDMI/audio/Wi-Fi/BT/camera/codec/NPU off (power) → headless ext.
  Vendor kernel string stays `6.6.98-vendor-sun60iw2`; tell custom vs stock apart via /proc/config.gz (DM_CRYPT).
- `roles/firstboot` + `roles/nvme` **work**: boards boot with root on `/dev/nvme0n1p1`, SD at `/media/sd`.
- 2026-09-02: all three boards run the custom kernel `26.08.0-k8s.1` (packages held), verified via `make kernel-install`.
- 2026-09-02 evening: `make bootstrap` completed through k3s (3 servers Ready, v1.36.4+k3s1) as `ops`; SD cards removed,
  u-boot in SPI NOR. Firewall allows only the nodes' /24 (hardening_lan_cidrs) + hardening_admin_hosts: 192.168.68.60 (Pi, control_host_ip)
  and .12 (laptop) — not the LAN.
  Backup play done: restic repo initialised, first snapshot taken, timers set; both kubeconfigs fetched. `make bootstrap` is
  fully verified on hardware. Storage Box facts: restricted shell (only file cmds, no `true`, no `&&`), sub-account SFTP is
  chrooted (login dir /home, `/` unreadable) → restic paths are RELATIVE (`opi-k8s/restic`); an agent with many keys trips
  MaxAuthTries → always `-o IdentitiesOnly=yes`; env files sourced by bash must quote values with spaces.
  Owner runs Ansible from a Raspberry Pi on the boards' LAN (`~/homelab/cluster`, same tree synced with the laptop),
  not from the laptop; the laptop cannot always reach 192.168.69.x directly.

## Known untested / fragile spots (highest risk first)

1. `roles/nvme` both stages verified 2026-09-02: all three boards boot from SPI with NO SD card (root + /boot on NVMe).
   The removed SD cards are the rescue disks (their own OS boots, rootdev already points at the NVMe).
2. `roles/firstboot`: relies on Armbian allowing non-interactive root SSH with default password `1234`.
   Some builds force a password change → use `scripts/prepare-sd.sh`. Netplan interface name comes from facts.
3. Longhorn S3 backup target (B2) — untested: bucket name/region in values, endpoint + keys in tfvars. (CIFS to the Storage Box is
   impossible from home: the ISP drops port 445 at its edge, verified with TCP traceroute 2026-09-02.)
4. `scripts/restore-longhorn-volumes.sh`: mimics Longhorn UI "create PV/PVC"; field names from BackupVolume
   status (`KubernetesStatus`, `lastBackupName`) need confirming against 1.12. `DRY_RUN=1` first.
5. (done 2026-09-03) all charts `helm template` clean and deployed; Longhorn manager can lose a startup race on the
   `guaranteed-instance-manager-cpu` setting and crash-loop once on one node — it self-heals on restart.
6. (done) Tofu validated + applied: the root Application is a 2nd helm_release (argocd-apps); `file()` is not allowed
   in tfvars (hence git_ssh_private_key_file); backend/providers use kubeconfig-tailscale.
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
