# opi-k8s — 3× Orange Pi Kubernetes lab (k3s · Tailscale · ArgoCD · Longhorn · Prometheus/Grafana)

Three layers, each owning one thing:

| Layer | Tool | Owns | Runs |
|---|---|---|---|
| Nodes | **Ansible** | Armbian prep, Tailscale, OS + k3s hardening, k3s HA (3 servers, embedded etcd) | once, re-run when nodes change |
| Bootstrap | **OpenTofu** | ArgoCD install + the handful of Secrets git must never contain | once |
| Everything else | **ArgoCD** (GitOps) | Longhorn storage, monitoring stack, Tailscale operator, updates, ArgoCD itself — reconciled from `gitops/` | continuously |
| Data safety | **Longhorn** + **restic** → Hetzner Storage Box | replicated + encrypted volumes, daily off-site backups of volumes and etcd | continuously |

After bootstrap, **you change the cluster by pushing to git.** ArgoCD prunes what you delete and heals what drifts.

```
ansible/          node prep + k3s          (Ansible)
tofu/             ArgoCD + secrets         (OpenTofu, run once)
gitops/
  bootstrap/      app-of-apps Helm chart: one Application per component, versions pinned here
  argocd/         values for ArgoCD (self-managed)
  monitoring/     values + extra manifests (alerts, dashboards) for kube-prometheus-stack
  tailscale/      values + tailnet Ingresses for the Tailscale operator
  longhorn/       replicated encrypted storage, StorageClasses, recurring backup jobs
  system-upgrade/ k3s auto-upgrade Plan (patch releases of the pinned minor)
  kured/          safe rolling reboots after OS updates
scripts/          backup-key (SSH-agent-derived passphrase), config backup, volume restore
mise.toml         pinned CLI tool versions (`mise install`)
renovate.json     PRs when k3s / charts / mise tools have new releases
```

## Pinned versions (all GA/stable releases, verified 2026-09-01)

CLI tools (`mise.toml`, exact pins, stable only): OpenTofu 1.12.6 · Ansible 13.x (core 2.20) · kubectl 1.36.4 · Helm 4.2.4 · restic 0.19.1 · jq 1.8.2 · jq 1.8.2 · kustomize 5.x (lint only). `mise install` once; Renovate bumps them (`ignoreUnstable` is on, so never an rc/beta).

| Component | Version | Where to bump |
|---|---|---|
| k3s | v1.36.4+k3s1 | `ansible/group_vars/all.yml` |
| longhorn chart | 1.12.0 | `gitops/bootstrap/templates/longhorn.yaml` |
| argo-cd chart | 10.4.2 | `gitops/bootstrap/templates/argocd.yaml` (+ `tofu/variables.tf` for first install) |
| kube-prometheus-stack chart | 88.3.0 | `gitops/bootstrap/templates/monitoring.yaml` |
| tailscale-operator chart | 1.102.3 | `gitops/bootstrap/templates/tailscale.yaml` |
| kernel (Orange Pi 4 Pro) | 6.6.98 vendor, custom build `26.08.0-k8s.1` | `kernel/userpatches/VERSION`, armbian/build commit in `scripts/build-kernel.sh` |
| system-upgrade-controller | v0.18.0 | `gitops/system-upgrade/kustomization.yaml` |
| kured chart | 6.0.0 | `gitops/bootstrap/templates/kured.yaml` |
| hashicorp/helm provider | ~> 3.2 | `tofu/versions.tf` |

Enable Renovate on the repo and it will open PRs for these automatically.

## Prerequisites

- [mise](https://mise.jdx.dev) — `make deps` installs every CLI tool at the pinned version, plus `sshpass` from your OS package manager (used once to install a key on the Storage Box)
- Three boards flashed with a **stock Armbian** image (Debian trixie minimal, `vendor` kernel — the only branch Armbian offers for this board), NVMe fitted, booted from SD. Nothing else — no wizard, no user, no password.
- `sshpass` on your machine (the first login uses Armbian's default root password)
- **Docker** on your machine — `make kernel` builds the custom kernel inside a container (~15 GB of cache, 30–60 min)
- A git remote ArgoCD can reach (GitHub/GitLab/Gitea — public or private)
- Tailscale account
- A **Hetzner Storage Box** with SSH and Samba enabled (Storage Box → Settings)
- An **Ed25519 SSH key in your agent** — it's the root of the backup encryption key (see *Backups*)

## 1. Configure

```bash
make deps
cp .env.example .env && vim .env          # K3S_TOKEN, TAILSCALE_AUTHKEY, STORAGEBOX_* — mise loads it automatically
make key                                  # derived from your SSH agent; SAVE THIS in your password manager
make kernel                               # custom vendor kernel → kernel/debs/ (see *Custom kernel* below)

vim ansible/inventory/hosts.yml           # node IPs + the user you SSH in as TODAY (root is fine for the first run)
vim ansible/group_vars/all.yml            # hardening_ssh_pubkeys (defaults to ~/.ssh/id_ed25519.pub), LAN CIDR if not a /24

# LAN-specific bits in git:
vim gitops/monitoring/values.yaml         # node IPs (once, YAML anchor) + grafana host
vim gitops/argocd/values.yaml             # argocd host
vim gitops/longhorn/values.yaml           # backupTarget: your Storage Box SMB path

cp tofu/terraform.tfvars.example tofu/terraform.tfvars
vim tofu/terraform.tfvars                 # git_repo_url (this repo), optional deploy key / Tailscale OAuth

git add -A && git commit -m "configure" && git push
```

## Custom kernel (why `make kernel` exists)

Armbian's `vendor` kernel for the Orange Pi 4 Pro (Allwinner A733, Linux 6.6) is built **without device-mapper,
dm-crypt, iSCSI and CIFS**. Longhorn needs iSCSI to attach volumes, the default `longhorn-encrypted` class is
LUKS, and Longhorn's backup target is SMB — so the stock kernel cannot run this repo's storage layer at all.

`make kernel` rebuilds the *same* kernel (same source branch, same armbian/build commit the boards were imaged
from) with those options enabled, plus a **headless/low-power** trim: no HDMI/DRM, framebuffer, audio, Wi-Fi,
Bluetooth, camera, video codec, NPU or touchscreen drivers. Nodes are reachable over SSH and the debug UART only.
`KERNEL_HEADLESS=0 make kernel` keeps the display and radio drivers if you ever need a screen.

The build runs in Docker and drops `linux-{image,dtb,headers}-vendor-sun60iw2_*.deb` into `kernel/debs/`
(git-ignored; included in `make backup-config`). `roles/kernel` installs them on every node, `apt-mark hold`s
them so Armbian's repo cannot replace them, and reboots a node only if its running kernel still lacks dm-crypt.
It also blacklists the Wi-Fi/BT/video modules and masks `bluetooth`, `aic8800-bluetooth` and `wpa_supplicant`.

**Canary + upgrades:** `make kernel-install LIMIT=opi-2` installs on one board and reboots it; check it comes back
before `make bootstrap`. To upgrade later: bump `kernel/userpatches/VERSION`, optionally move the armbian/build
commit in `scripts/build-kernel.sh`, `make kernel`, then `make kernel-install` (one node at a time, drained and
uncordoned). Armbian ships no stable release for this board; everything is a
`trunk` nightly, which is why the build is pinned to a commit rather than a tag.

## 2. Nodes — from a blank SD card

Flash Armbian, plug in, power on. Find each board's DHCP address on your router and put it in `hosts.yml` as `firstboot_ip`, with the static IP you want it to keep as `ansible_host`. Then:

```bash
make bootstrap                  # ~20 min: firstboot → NVMe migration → prep → Tailscale → hardening → k3s
make nodes                      # 3× Ready  control-plane,etcd
```

What the first play does to each board, in order:

1. Logs in as `root` with Armbian's default password (`1234`; override with `ARMBIAN_ROOT_PASSWORD`), or your key if you pre-seeded the card with `scripts/prepare-sd.sh`.
2. Removes the first-login wizard, installs your SSH key, replaces the default root password with a random one (saved to `ansible/secrets/root_password_<node>` for console use), sets the locale.
3. Writes a netplan static config and jumps to the inventory IP.
4. **Moves the OS to NVMe**: partitions, formats, rsyncs the root filesystem, points the SD's `armbianEnv.txt` at the NVMe root, reboots. `/boot` stays on the SD (bind-mounted) so u-boot and kernel updates keep working, and the SD's original OS remains as a fallback (`/boot/ROLLBACK.txt` says how). Refuses to touch an NVMe that already has partitions unless `nvme_wipe: true`.

Then the normal roles run on the NVMe-backed system. Re-runs are no-ops for all of this (root already on NVMe → skipped; already on static IP → skipped). Delete the `firstboot_ip` lines and switch `ansible_user` to `ops` afterwards.

Full NVMe boot (no SD at all) needs u-boot written to the board's SPI flash — that's board-specific and a one-liner in `armbian-config` → System → Install; do it by hand once if you want it. Everything here keeps working either way.

You get two kubeconfigs: `kubeconfig` (LAN) and `kubeconfig-tailscale` (works from anywhere).

**After the first run, root SSH is off.** Set `ansible_user: ops` (the `hardening_admin_user`) in the inventory before running the playbook again. Tailscale SSH is also enabled as a fallback path.

## 3. ArgoCD

```bash
make argocd                     # tofu apply: ArgoCD + secrets + root Application
make argocd-password            # admin login → http://argocd.<node-ip>.nip.io
make apps                       # watch root → argocd, longhorn, monitoring, kured, system-upgrade go Synced/Healthy
```

First sync takes a few minutes on the Pis (kube-prometheus-stack CRDs are big). Then:

- **Grafana** — `http://grafana.<node-ip>.nip.io`, `admin` / `make grafana-password`. Home dashboard is the cluster overview; *Node Exporter Full* has per-board temperature.
- **Alerts** — `gitops/monitoring/manifests/sbc-alerts.yaml` adds SoC temperature, disk, memory alerts on top of the stack's defaults. Wire Alertmanager to Discord/Telegram/email by adding `alertmanager.config` to the values.

### Tailscale operator (optional)

1. Admin console → Access Controls, add tags:
   `"tagOwners": { "tag:k8s-operator": [], "tag:k8s": ["tag:k8s-operator"] }`
2. Admin console → Trust credentials → OAuth client with **Devices Core (write)**, **Auth Keys (write)** and **Services (write)** scopes, tag `tag:k8s-operator`
3. DNS → enable MagicDNS + HTTPS certificates
4. Put client id/secret in `terraform.tfvars`, `make argocd` (creates the `operator-oauth` Secret)
5. Set `tailscale.enabled: true` in `gitops/bootstrap/values.yaml`, push

Grafana and ArgoCD appear as `https://grafana.<tailnet>.ts.net` / `https://argocd.<tailnet>.ts.net` with real certs, and `tailscale configure kubeconfig tailscale-operator` gives you kubectl over the tailnet governed by Tailscale ACLs.

## Storage & failover

Longhorn replicates every volume to **2 of the 3 nodes** (different nodes, enforced). Prometheus, Grafana and Alertmanager all use the default `longhorn-encrypted` class. If a node dies:

1. Kubernetes marks it NotReady (~40 s).
2. Longhorn's `nodeDownPodDeletionPolicy` force-deletes the stuck pods (StatefulSets don't do this on their own — they'd wait forever).
3. The pod reschedules on a surviving node, Longhorn attaches the volume from the remaining replica, and rebuilds the second replica when a node is back. Expect 1–3 minutes of Grafana downtime, no data loss.

Volumes are **LUKS-encrypted** on disk (`dm-crypt`, key in the `longhorn-crypto` Secret) — pulling an SD card gives you ciphertext. Grafana gets Longhorn dashboards automatically; alerts fire on degraded volumes, unreachable backup target, or a volume with no backup in 36 h.

## Backups

Everything on the Storage Box is encrypted; **one passphrase** unlocks it all, and it's derived from your SSH key rather than stored anywhere:

```
scripts/backup-key.sh  →  ssh-keygen -Y sign (Ed25519 = deterministic)  →  sha256  →  BACKUP_KEY
```

The private key never leaves your agent (1Password, Secretive, plain ssh-agent all work). Same key, same message, same passphrase, forever. The script signs with `~/.ssh/id_ed25519.pub` by default; set `BACKUP_SSH_PUBKEY=/path/to/key.pub` in `.env` to use a different Ed25519/RSA key (it must be loaded in the agent; ECDSA/FIDO keys are rejected because their signatures are randomised). Pick the key **once** — changing it later changes the passphrase and orphans every existing backup. **Store the printed key in a password manager too** — lose the SSH key and you lose the backups.

| What | Tool | Where on the box | Schedule | Retention |
|---|---|---|---|---|
| Longhorn volumes (Grafana, Prometheus, Alertmanager, anything on the default class) | Longhorn backup → SMB | `/opi-k8s/longhorn` | daily 01:30 + weekly | 14 daily / 8 weekly |
| etcd snapshots + `/etc/rancher/k3s` (token, config) | restic → SFTP, from every server | `/opi-k8s/restic` | daily 03:10/03:20/03:30 | 7d / 4w / 3m, integrity check weekly |
| Tofu tfvars + lock file, kubeconfigs, Storage Box key, `.env` | restic → SFTP, from your laptop | `/opi-k8s/restic` | on every `make argocd`, or `make backup-config` | last 10 |

Longhorn's backups are block-level incremental of the *encrypted* device, so the Storage Box only ever sees LUKS ciphertext. restic encrypts with the same `BACKUP_KEY`.

## Recreate the whole cluster from backup

Fresh SD cards, same boards (or new ones — only `hosts.yml` changes). Roughly 30 minutes, mostly waiting.

```bash
# 0. laptop: clone the repo, mise install, SSH key in agent
make deps && export BACKUP_KEY=$(make -s key)
# 1. get your local secrets back (tfvars, storagebox key, .env) — Tofu state isn't needed, a fresh cluster starts empty
STORAGEBOX_USER=u123456 STORAGEBOX_HOST=u123456.your-storagebox.de make backup-restore-config
# 2. nodes + k3s (restic repo already exists on the box → reused)
make bootstrap
# 3. pause data-bearing apps, bootstrap ArgoCD → Longhorn comes up and syncs the backup target
sed -i 's/^  enabled: true/  enabled: false/' gitops/bootstrap/values.yaml   # monitoring.enabled=false
git commit -am "dr: pause monitoring" && git push
make argocd
kubectl -n longhorn-system get backupvolumes      # wait until your volumes are listed
# 4. restore every volume + PV/PVC with original names
make restore-volumes
kubectl -n longhorn-system get volumes.longhorn.io -w   # until restored volumes are 'detached'
# 5. resume: monitoring binds to the restored PVCs
git revert HEAD && git push
make apps
```

Grafana history, dashboards you made, Prometheus data — all back. If you'd rather restore *everything* including Kubernetes objects that never went through git, k3s can also restore an etcd snapshot: `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>` on the first node (snapshots are in the restic repo under `/var/lib/rancher/k3s/server/db/snapshots`). With GitOps that's rarely worth it.

**Test the restore path before you need it.** `DRY_RUN=1 make restore-volumes` shows what it would do; a full rehearsal on the live cluster is safe because `reclaimPolicy: Retain` means nothing is deleted.

## Working from another computer

```bash
git clone <repo> && cd opi-k8s && make deps        # tools
# your SSH key in the agent (same one — it IS the backup key)
STORAGEBOX_USER=... STORAGEBOX_HOST=... make backup-restore-config   # tfvars, kubeconfigs, .env
make apps                                          # kubeconfig works → so does everything else
```

Tofu state needs no copying: `tofu init` finds it in the cluster. If two people/machines run `make argocd` at once, the second one waits on the lock.

## Day-2

| Want to… | Do |
|---|---|
| Add an app | new `gitops/bootstrap/templates/<app>.yaml` Application (copy monitoring.yaml) + a values file; push |
| Bump a chart | edit `targetRevision`, push. ArgoCD applies; `make apps` shows health |
| Bump k3s minor | edit the channel in `gitops/system-upgrade/plan-k3s.yaml` (one minor at a time) and `k3s_version` in Ansible; push. Patches are automatic |
| Armbian kernel / full OS upgrade | `make os-upgrade` — drains, upgrades, reboots, uncordons one node at a time |
| Bump ArgoCD | edit `gitops/bootstrap/templates/argocd.yaml`; ArgoCD upgrades itself. Also update `tofu/variables.tf` so a fresh bootstrap matches |
| Rotate Grafana password | change in tfvars, `make argocd`, restart the grafana pod |
| Nuke a node | `ssh <node> /usr/local/bin/k3s-uninstall.sh`, `make bootstrap` |
| Remove everything in-cluster | `make destroy` (ArgoCD finalizers cascade-delete the apps; Longhorn data stays on disk and on the Storage Box) |
| Rotate the backup key | not in place — new SSH key → new key → re-encrypt: new StorageClass secret, migrate volumes (Longhorn docs), `restic key add` |

## Updates — what happens automatically

| Layer | Mechanism | Cadence | Reboot? |
|---|---|---|---|
| OS security patches | `unattended-upgrades`, Debian/Ubuntu security pockets only | daily | no — flags `/var/run/reboot-required` (needrestart detects kernel/libc changes) |
| Node reboots | **kured** DaemonSet — takes a cluster lock, drains, reboots, uncordons, next node | window 03:00–05:00 UTC, one node at a time | yes, safely |
| Service restarts after lib updates | `needrestart` in automatic mode | with each apt run | no |
| k3s patch releases | **system-upgrade-controller** Plan tracking the `v1.36` channel — cordon, drain, upgrade, one server at a time | polls hourly | no (k3s restarts in place) |
| Tailscale | `tailscale set --auto-update` | Tailscale's stable track | no |
| Charts / ArgoCD / k3s minors / operator versions | **Renovate** PRs → you merge → ArgoCD syncs | on release | depends |
| Armbian packages (kernel, u-boot, firmware) | **manual**: `make os-upgrade` (rolling, drained) — or set `updates_include_armbian_repo: true` to let kured handle it | you decide | rolling |

Opt a node out of k3s auto-upgrades: `kubectl label node opi-2 k3s-upgrade=disabled`.
Get notified on reboots: set `configuration.notifyUrl` in `gitops/kured/values.yaml` via a Secret (shoutrrr URL: Discord, Telegram, Slack, email…).

## What "hardened" means here

**OS (Ansible `hardening` role, idempotent, re-runnable)**

- Dedicated `ops` admin user with your public key(s) + passwordless sudo; root SSH disabled, password auth disabled, modern ciphers/KEX only, weak host keys removed, `AllowUsers` pinned. sshd config is validated (`sshd -t`) before restart so a typo can't lock you out.
- **nftables host firewall, default-drop on input**, written to coexist with k3s (it never `flush ruleset`s). Allowed: loopback, established, ICMP, the pod/service CIDRs and CNI interfaces, the other two nodes (etcd/kubelet/VXLAN/metrics), `tailscale0` + WireGuard 41641/udp, DHCP, and from your LAN only: 22, 80, 443, 6443. Everything else is dropped and rate-limited-logged. Add NodePorts etc. via `hardening_extra_nft_input_rules`.
- Kernel sysctls: rp_filter (loose, CNI-safe), no redirects/source-routing, martian logging, syncookies, `kptr_restrict`, `dmesg_restrict`, unprivileged BPF off, Yama ptrace scope, protected fifos/regular/links, no SUID dumps. Rare filesystem/protocol modules blacklisted.
- fail2ban on sshd (LAN + tailnet whitelisted), journald capped at 200 MB / 14 days to protect the SD card, avahi/bluetooth/cups/rpcbind masked, umask 027, stronger password hashing.
- Unattended **security** updates with drained, windowed reboots via kured (see *Updates* above).

**Kubernetes (k3s config)**

- Secrets encrypted at rest, `protect-kernel-defaults`, anonymous API auth off.
- **Pod Security Admission**: `baseline` enforced cluster-wide (blocks privileged/hostPath/hostNetwork pods by default), `restricted` warned/audited. `kube-system` is exempt; `monitoring` and `tailscale` are explicitly labeled `privileged` by Tofu because node-exporter and the Tailscale proxies legitimately need it. New namespaces you create get `baseline` — if a chart needs more, label the namespace, don't loosen the default.
- API **audit log** (`/var/lib/rancher/k3s/server/logs/audit.log`, 7 days × 50 MB): metadata for reads, full request for writes, secret bodies never logged.
- etcd snapshots every 6 h, 12 retained.

**Not done (on purpose)** — CIS `profile: cis` mode (too restrictive for a homelab, breaks many charts), auditd (heavy on SBCs), default-deny NetworkPolicies (add per-namespace when you have workloads worth isolating). All are straightforward follow-ups.

## Design notes

- **3 servers, no agents** — etcd quorum + every board schedulable. k3s snapshots etcd every 6h (`/var/lib/rancher/k3s/server/db/snapshots`); copy those off-box if you care about the data.
- **Tofu state is in the cluster**, not on your laptop: a Secret in `kube-system` (kubernetes backend, with locking), encrypted twice — by k3s at rest and by OpenTofu's native state encryption with your `BACKUP_KEY`. Any machine with the kubeconfig + your SSH key in the agent can run `make argocd`. After a rebuild the state is empty, which is correct: Tofu just recreates its resources. `make state-show` to inspect.
- **Secrets never touch git.** Tofu creates them; charts reference them by name (`grafana.admin.existingSecret`, `operator-oauth`). If you later want secrets in git, add External Secrets or SOPS as another Application.
- **ArgoCD manages itself.** Tofu installs it once and then `ignore_changes` on the release, so it doesn't fight git. Tofu is only needed again for a fresh cluster.
- **ServerSideApply + ignoreDifferences** on the monitoring app are required: the Prometheus CRDs exceed the client-side annotation limit, and the operator injects webhook CA bundles at runtime.
- **k3s hardening:** secrets-encryption at rest, `protect-kernel-defaults`, anonymous API auth off, unattended security updates (kernel/Tailscale excluded so nothing surprises you).
- **Tailscale is for access**, not the pod network — flannel stays on the LAN. For multi-site, k3s can run flannel over Tailscale (`vpn-auth` in `config.yaml.j2`).
- **Tailscale SSH** is on; add an `ssh` rule to your tailnet ACLs or it silently falls back to normal SSH.
- **Storage** is Longhorn (2 replicas, encrypted). `local-path` still exists for throwaway data. Longhorn's own UI is only exposed on the tailnet (it has no auth).
- **SMB password** — Longhorn's CIFS backup target can't use SSH keys, so the Storage Box password lives in a Secret (Tofu) and in your tfvars. Consider a Storage Box *sub-account* limited to `/opi-k8s` with its own password.
- **Memory** is the constraint on SBCs — limits are deliberately small. If Prometheus OOMs, lower `retentionSize` or raise its limit.
