# Bootstrap walkthrough

What actually happens when you run `make deps`, `make key`, `make kernel`, `make bootstrap` and `make argocd`
against the three Orange Pi 4 Pro boards, step by step, with what each step changes on a board and how to
check it worked. Written from the repo as it stood on 2026-09-02 and from the `make bootstrap` run of that day.
Read this together with `README.md` (runbooks) and `CLAUDE.md` (design decisions and hardware facts).

Contents

1. [Prerequisites on the control machine](#1-prerequisites-on-the-control-machine)
2. [What `make bootstrap` does](#2-what-make-bootstrap-does)
3. [The custom kernel](#3-the-custom-kernel)
4. [After bootstrap: `make argocd`](#4-after-bootstrap-make-argocd)
5. [Things that bit us on real hardware](#5-things-that-bit-us-on-real-hardware)
6. [Day-2 pointers](#6-day-2-pointers)

## 1. Prerequisites on the control machine

The control machine is whatever runs `make`. On 2026-09-02 that was a Raspberry Pi on the boards' LAN, reached
from the laptop with `ssh -A` so the laptop's SSH agent is available there. The laptop itself is WSL2 with
Docker Desktop and is where `make kernel` runs.

| Need | Why | Check |
|---|---|---|
| `mise` | Installs every CLI tool at the pinned version from `mise.toml` and loads `.env` | `mise --version` |
| Docker | `make kernel` builds the kernel inside an Armbian build container | `docker info` |
| `sshpass` | First login to a fresh board uses Armbian's default root password; also used once to install the restic key on the Storage Box | `command -v sshpass` |
| Cluster SSH key in the agent | `hardening_ssh_pubkeys` in `ansible/group_vars/all.yml` reads `~/.ssh/id_ed25519_cluster.pub`. Its private key must be loaded in the agent, because every Ansible connection after first boot is key based | `ssh-add -L \| grep cluster` |
| The same key as backup key signer | `.env` sets `BACKUP_SSH_PUBKEY=/home/user/.ssh/id_ed25519_cluster.pub`. Without that line `scripts/backup-key.sh` falls back to `~/.ssh/id_ed25519.pub`, which does not exist on this machine | `make key` prints 64 hex characters |
| `.env` | Git-ignored. mise loads it into the environment of every command run in the repo | `mise env \| grep STORAGEBOX_USER` |

`.env` contents (see `.env.example`):

| Variable | Used by |
|---|---|
| `K3S_TOKEN` | `roles/k3s` (cluster join secret) |
| `TAILSCALE_AUTHKEY` | `roles/tailscale` (`tailscale up`) |
| `STORAGEBOX_USER`, `STORAGEBOX_HOST` | `roles/backup`, `scripts/backup-config.sh`, Tofu (`TF_VAR_storagebox_user`) |
| `STORAGEBOX_PASSWORD` | `roles/backup`, only the first time, to install the restic SSH key on the box |
| `BACKUP_SSH_PUBKEY` | `scripts/backup-key.sh`. Pick once, never change |
| `ARMBIAN_ROOT_PASSWORD` (optional, not in the example) | Play 1 of `site.yml` if a board's default root password is not `1234` |

mise also sets `KUBECONFIG` to `<repo>/kubeconfig`, so `kubectl` works from anywhere inside the repo once
bootstrap has written that file.

### `make deps`

Runs `mise install`. Tools come from `mise.toml`: OpenTofu, kubectl, Helm, kustomize, restic, jq, uv, and the
`ansible` community package via `pipx:ansible` with `uvx_args = "--with-executables-from ansible-core"`.
That last flag matters: the `ansible` package bundles the collections, but the `ansible-playbook` executable
belongs to its dependency `ansible-core`, and uv only exposes entry points of the named package. Without the
flag you get the collections and no `ansible-playbook`. Nothing else installs collections; `roles/` use
`ansible.posix`, `community.general` and `community.crypto` from the bundle.

### `make key`

Runs `scripts/backup-key.sh`. It asks the SSH agent to sign a fixed message (`opi-k8s cluster backup key v1`,
namespace `opi-k8s-backup`) with the public key from `BACKUP_SSH_PUBKEY`, strips the signature armour and
prints its sha256. Ed25519 and RSA signatures are deterministic, so the same key always gives the same
64-character string. That string is `BACKUP_KEY`: the restic repository password on every node and on the
laptop, the Longhorn LUKS passphrase and the OpenTofu state encryption passphrase. The Makefile evaluates it
once per invocation (`BACKUP_KEY ?= $(shell scripts/backup-key.sh)`) and refuses to run `bootstrap` or
`argocd` when it comes back empty. Store the printed value in a password manager. On WSL2 the signing call can
block on a Windows-side approval prompt (see section 5h).

### `make kernel`

Runs `scripts/build-kernel.sh`. Details in section 3. In short: it clones `armbian/build` at the commit the
boards' images were built from, copies `kernel/userpatches/` in, runs `./compile.sh kernel` in Docker with
the `k8s-storage`, `docker-dns` and `headless-lowpower` extensions, and leaves the `.deb` files in
`kernel/debs/`. Expect 30 to 60 minutes and about 15 GB under `kernel/build/` the first time. `kernel/debs/`
is git-ignored, so it has to be copied to the control machine if that is not where you built it.

## 2. What `make bootstrap` does

The Makefile checks that `BACKUP_KEY` is non-empty, then runs `cd ansible && ansible-playbook site.yml`.
`ansible/ansible.cfg` supplies the inventory (`inventory/hosts.yml`), disables host key checking, turns on
pipelining and `ControlPersist=60s`, and sets `callback_result_format = yaml` for readable task results.

The inventory has three hosts: `opi-1` in group `k3s_init`, `opi-2` and `opi-3` in `k3s_servers`, all three
in `k3s_cluster`. `ansible_host` is the static IP each board should end on (192.168.69.101 to .103). A
commented `firstboot_ip` per host is the DHCP address the board had on first power-on. Group vars set
`ansible_user: root` and `ansible_become: true`.

`site.yml` is six plays, run in this order:

| # | Play | Hosts | Connects as | Roles / tasks |
|---|---|---|---|---|
| 1 | First boot | k3s_cluster | `root` if `firstboot_ip` is set, else the inventory user | `firstboot`, `nvme` (if `nvme_enabled`) |
| 2 | Prepare Armbian nodes | k3s_cluster | inventory user (`root` on the first run) | `kernel` (if `kernel_custom_enabled`), `common`, `tailscale`, `hardening`, `updates` |
| 3 | Bootstrap first k3s server | k3s_init, serial 1 | `ops` (`hardening_admin_user`) | `k3s` with `k3s_role: init` |
| 4 | Join remaining servers | k3s_servers, serial 1 | `ops` | `k3s` with `k3s_role: server` |
| 5 | Off-site backups | k3s_cluster | `ops` | `backup` |
| 6 | Fetch kubeconfig | k3s_init | `ops` | slurp `/etc/rancher/k3s/k3s.yaml`, write two local kubeconfigs, print `kubectl get nodes` |

Plays 3 to 6 force `ansible_user` to `ops` because the `hardening` role turns root SSH off at the end of
play 2. Play 1 and 2 still use the inventory user, so the inventory must say `root` on the very first run and
`ops` on every run after that.

### Play 1, role `firstboot`

Runs against whatever the board is right now. With `firstboot_ip` set it connects to that DHCP address as
`root` with password `1234` (or `ARMBIAN_ROOT_PASSWORD`) and `StrictHostKeyChecking=no`. Without it, it
connects to `ansible_host` with the inventory user and key.

What it changes:

- Deletes `/root/.not_logged_in_yet`, which is the flag that triggers Armbian's interactive first-login wizard.
- Adds every key in `hardening_ssh_pubkeys` to root's `authorized_keys`, so the rest of the run is key based.
- Generates a 24-character root password with the `password` lookup, which stores it in
  `ansible/secrets/root_password_<node>` (git-ignored), hashes it on the board with `openssl passwd -6` and
  sets it. This replaces the public default password. Keep the file; it is the serial-console login.
- Generates the locale `en_IE.UTF-8` and writes `/etc/default/locale`.
- Makes sure `python3` exists (raw `apt-get install` if not).
- If `static_ip_enabled` and the board's current address is not `ansible_host`: moves Armbian's DHCP netplan
  files aside, writes `/etc/netplan/10-static.yaml` from the facts' default interface with the address,
  `/22` prefix, gateway `192.168.68.1` and DNS from `group_vars`, applies netplan asynchronously, switches
  `ansible_host` to the static address and waits up to 120 s for it. On a re-run the whole block is skipped.
- Re-gathers facts on the new address.

How to tell it worked: the play continues on the static IP; `ansible/secrets/root_password_<node>` exists;
on the board `cat /etc/netplan/10-static.yaml` shows the static address and `ip -4 addr` agrees.

### Play 1, role `nvme`

Only runs its work block when `findmnt -no SOURCE /` does not contain `nvme`. Otherwise it prints
"already NVMe, nothing to do" and moves on, which is what the 2026-09-02 log shows for all three boards.

On a fresh board it:

- Asserts `/dev/nvme0n1` exists. Refuses to touch a disk that already has partitions unless `nvme_wipe` is
  true (it is true in `group_vars`).
- Creates one GPT partition, formats it ext4 with label `nvme_root`, mounts it on `/mnt/nvme`.
- `rsync -aAXH` copies the running root filesystem onto it, excluding `/dev`, `/proc`, `/sys`, `/tmp`,
  `/run`, `/mnt`, `/media` and the apt cache.
- Writes an fstab on the new root: NVMe as `/`, the SD partition at `/media/sd`, and `/media/sd/boot`
  bind-mounted over `/boot`. So `/boot` (kernel, initrd, dtb, `armbianEnv.txt`) always lives on the SD, where
  u-boot looks for it.
- Rewrites `rootdev=` in the SD's `/boot/armbianEnv.txt` to the NVMe UUID and leaves `/boot/ROLLBACK.txt`
  with the one-line `sed` that points it back at the SD's own OS.
- Reboots (first reboot of a fresh bootstrap) and verifies `/` is on NVMe.

How to tell it worked: `findmnt / /boot /media/sd` on the board shows `/dev/nvme0n1p1`, a bind mount, and the
SD partition. The SD keeps a complete bootable copy of the pre-migration OS as a fallback.

### Play 2, role `kernel`

Installs the custom kernel from `kernel/debs/` and holds it. Section 3 has the why and the recovery story.
In run order:

- On the control machine (`delegate_to: localhost`, with `ansible_become: false` as a var, see 5d) it finds
  `linux-*-vendor-sun60iw2_*.deb` in `kernel/debs/` and asserts there is exactly one `linux-image` and one
  `linux-dtb`. Missing debs stop the play with a pointer to `make kernel`.
- Checks `/boot` is a mount (`findmnt -n /boot`) when `nvme_enabled`, because the kernel postinst writes there
  and it must be the SD bind mount, not a directory on the NVMe.
- Copies the debs to `/var/cache/opi-k8s-kernel/` on the node, in the order dtb, headers, image.
- Compares `dpkg-deb -f ... Version` of the staged image with `dpkg-query -W linux-image-vendor-sun60iw2`.
  Only when they differ: copies the current `/boot/Image`, `uInitrd`, `vmlinuz-*`, `initrd.img-*`,
  `System.map-*`, `config-*` and `dtb-*` into `/boot/stock-kernel-backup/` (once, guarded by `creates`),
  writes a `README.txt` beside them, and runs `apt install` on each deb with `allow_downgrade`.
- `apt-mark hold` on all three package names so the Armbian repository cannot replace them.
- Checks the running kernel: `zcat /proc/config.gz` must contain `CONFIG_DM_CRYPT=[my]` and
  `CONFIG_ISCSI_TCP=[my]`.
- Reboots, `throttle: 1` so one node at a time, only if apt installed something or the running kernel failed
  that check. Second reboot point of a fresh bootstrap.
- `modprobe dm_crypt`, `iscsi_tcp`, `cifs` as a hard verification.
- If `kernel_headless`: writes `/etc/modprobe.d/opi-headless.conf` blacklisting the Wi-Fi, Bluetooth,
  touchscreen, codec, NPU and blitter modules, and masks `bluetooth`, `aic8800-bluetooth` and
  `wpa_supplicant`. On the headless kernel those drivers do not exist and this is a no-op; it matters if you
  ever build with `KERNEL_HEADLESS=0`.

How to tell it worked: the "Verify the storage modules load" task is `ok` for all three modules; on the board
`dpkg-query -W linux-image-vendor-sun60iw2` prints `26.08.0-k8s.1` and `apt-mark showhold` lists the three
packages. In the 2026-09-02 log every install task was skipped because all boards already had the kernel.

### Play 2, role `common`

- Hostname = inventory name, `127.0.1.1 <name>` in `/etc/hosts`, timezone `Etc/UTC`.
- Installs `base_packages`: curl, ca-certificates, apt-transport-https, python3-apt, python3-debian,
  nfs-common, open-iscsi, jq, htop, chrony, cryptsetup, cifs-utils.
- Disables Armbian's zram swap (`/etc/default/armbian-zram-config`), `swapoff -a`, removes swap from fstab.
  A change here notifies the `reboot node` handler.
- Loads and persists `overlay`, `br_netfilter`, `dm_crypt`, `iscsi_tcp` (`/etc/modules-load.d/k8s.conf`).
  This is the task that failed on the stock kernel and started the custom-kernel work.
- Kubernetes sysctls in `/etc/sysctl.d/99-kubernetes.conf`, including the four that k3s
  `protect-kernel-defaults` insists on (`vm.overcommit_memory=1`, `vm.panic_on_oom=0`, `kernel.panic=10`,
  `kernel.panic_on_oops=1`).
- Appends `cgroup_enable=cpuset cgroup_enable=memory cgroup_memory=1 swapaccount=1` to `extraargs=` in
  `/boot/armbianEnv.txt` if missing. Also notifies `reboot node`.
- Enables `iscsid`.
- `meta: flush_handlers`, so the reboot (if notified) happens here, before Tailscale and k3s. Third possible
  reboot point; it does not fire on re-runs.

How to tell it worked: `swapon --show` prints nothing; `lsmod | grep -E 'dm_crypt|iscsi_tcp'` lists both;
`cat /proc/cmdline` contains `cgroup_memory=1`.

### Play 2, role `tailscale`

- Downloads Tailscale's signing key for the detected distro/release and adds the repo with
  `deb822_repository` (needs `python3-debian` on the node, see 5e).
- Installs and enables `tailscaled`.
- `tailscale status --json`; if `BackendState` is not `Running`, runs `tailscale up --authkey=...
  --hostname=<node> --ssh` (`no_log`). Skipped on re-runs.
- `tailscale set --auto-update=true`.
- Records `tailscale_ip` and `tailscale_dns` (MagicDNS name) as host facts. The k3s role puts both into the
  API server certificate (`tls-san`), and play 6 uses `tailscale_ip` for the second kubeconfig.

How to tell it worked: the "Show Tailscale identity" task prints `opi-N -> 100.x.y.z (opi-N.<tailnet>.ts.net)`
for each node. The 2026-09-02 log shows all three joined. Tailscale SSH (`tailscale ssh ops@opi-1`) is the
fallback path once LAN SSH is locked down, provided your tailnet ACLs have an `ssh` rule.

### Play 2, role `hardening`

This is the role that changes how you log in. Order matters and is preserved here.

- Asserts `hardening_ssh_pubkeys` is not empty (otherwise you would lock yourself out).
- Creates user `ops` in group `sudo`, installs the same public keys, writes
  `/etc/sudoers.d/90-ops` (`NOPASSWD:ALL`, validated with `visudo`).
- Writes `/etc/ssh/sshd_config.d/00-hardening.conf` (validated with `sshd -t`): `PermitRootLogin no`,
  `PasswordAuthentication no`, `AuthenticationMethods publickey`, `AllowUsers ops`, modern KEX/ciphers/MACs
  only, Ed25519 and RSA host keys only. Deletes the DSA and ECDSA host keys. Both notify `restart sshd`.
- Optionally locks the root password (`hardening_lock_root_password`, false by default, so the serial console
  still accepts the password from `ansible/secrets/`).
- Installs nftables, purges ufw/firewalld, renders `/etc/nftables.conf` (validated with `nft -c`) and enables
  the service. The ruleset defines only the `inet host_fw` table and never flushes the ruleset, so k3s's own
  iptables-nft tables survive. Input policy is drop; accepted are loopback, established, ICMP, pod and service
  CIDRs, `cni0`/`flannel.1`/`tailscale0`, the other node IPs, udp/41641, DHCP, and from `hardening_lan_cidrs`
  only tcp 22, 80, 443, 6443. Note that `hardening_lan_cidrs` defaults to the `/24` of each node's address
  (`192.168.69.0/24`) even though the boards sit on a `/22`; anything on `192.168.68.x` is not "LAN" to this
  firewall.
- Security sysctls in `/etc/sysctl.d/98-hardening.conf` (`failed_when: false`, some keys do not exist on the
  vendor kernel).
- Blacklists rarely used protocol and filesystem modules (`/etc/modprobe.d/hardening-blacklist.conf`).
- Masks avahi-daemon, bluetooth, cups, rpcbind.
- Creates `/etc/systemd/journald.conf.d/` (absent on minimal images, see 5f), caps the journal at 200 MB and
  14 days, notifies `restart journald`.
- Installs fail2ban with an sshd jail (systemd backend, nftables ban action, `ignoreip` = loopback, the
  Tailscale CGNAT range and `hardening_lan_cidrs`, 5 failures in 10 minutes gives a 1 hour ban), notifies
  `restart fail2ban`.
- `UMASK 027` and password ageing in `/etc/login.defs`; mode 0600 on `/etc/rancher` and `/boot/armbianEnv.txt`.

The handlers (`restart sshd`, `reload nftables`, `restart journald`, `restart fail2ban`) run at the end of
play 2, after the `updates` role. That is the exact moment root SSH stops working. Everything before it in
the same run still connected as root; everything after it connects as `ops`.

How to tell it worked: `ssh root@<node>` is refused and `ssh ops@<node> sudo -n true` succeeds;
`sudo nft list table inet host_fw` shows the sets `lan`, `nodes`, `cluster`; `sudo fail2ban-client status sshd`
answers. On a re-run every task should be `ok` and no handler should fire.

### Play 2, role `updates`

- Installs unattended-upgrades, apt-listchanges, needrestart.
- Writes `/etc/apt/apt.conf.d/52unattended-upgrades-local`: origins = the Debian security pocket only
  (plus `origin=Armbian` if `updates_include_armbian_repo`), blacklist `k3s` and `tailscale`,
  `Automatic-Reboot "false"`.
- Writes `20auto-upgrades` and enables `apt-daily.timer` and `apt-daily-upgrade.timer`.
- needrestart in automatic mode; an apt `DPkg::Post-Invoke` hook touches `/var/run/reboot-required` when
  needrestart reports a pending kernel. kured (in-cluster) watches that file.
- Ends with `unattended-upgrade --dry-run --debug`, which fails the play if the config does not parse.

How to tell it worked: the dry-run task is `ok`; `systemctl list-timers apt-daily*` shows both timers.
Because the held kernel packages come from the Armbian origin and that origin is excluded by default, the
custom kernel is never touched by unattended-upgrades.

### Play 3, role `k3s` as `init` (opi-1 only)

Now connecting as `ops` with sudo.

- Writes `/etc/rancher/k3s/psa.yaml` (PodSecurity: enforce `baseline`, warn and audit `restricted`,
  `kube-system` exempt) and `audit-policy.yaml`.
- Renders `/etc/rancher/k3s/config.yaml`: `cluster-init: true`, `token` from `K3S_TOKEN`, `node-ip` =
  `ansible_host`, `tls-san` = every node's LAN IP, Tailscale IP and MagicDNS name, secrets encryption,
  `protect-kernel-defaults`, etcd snapshots every 6 hours with 12 kept, audit log, anonymous auth off,
  control-plane metrics bound to 0.0.0.0.
- Downloads `https://get.k3s.io` to `/usr/local/bin/k3s-install.sh` and runs it with
  `INSTALL_K3S_VERSION=v1.36.4+k3s1` (guarded by `creates: /usr/local/bin/k3s`).
- Enables and starts `k3s`, waits for port 6443, then polls `kubectl get node opi-1` until `Ready`.
- Symlinks `/usr/local/bin/kubectl` to `k3s`.

Config changes on re-runs notify `restart k3s`, which only fires if the binary already exists.

How to tell it worked: `sudo kubectl get nodes` on opi-1 shows one Ready node with the
`control-plane,etcd,master` roles.

### Play 4, role `k3s` as `server` (opi-2, then opi-3, serial 1)

Same role, but `config.yaml` gets `server: https://192.168.69.101:6443` instead of `cluster-init`. Each node
installs, starts, waits for its own 6443 and its own Ready condition before the next one begins, so etcd
membership grows one at a time.

How to tell it worked: `kubectl get nodes` shows three Ready servers.

### Play 5, role `backup` (all nodes)

- Asserts `backup_key` is at least 32 characters and the Storage Box user and host are set.
- On the control machine (`run_once`): generates `ansible/secrets/storagebox_ed25519` if missing. If it was
  just generated and `STORAGEBOX_PASSWORD` is set, uses `sshpass` to append the public key to the box's
  `authorized_keys` over SSH on port 23 and creates `opi-k8s/restic` and `opi-k8s/longhorn` there.
  Both tasks use `become: false` but do not set the `ansible_become: false` var; see 5d for why that may still
  try `sudo` on the control machine. This play had not run yet when this document was written.
- Installs restic on the node, writes `/etc/restic/{storagebox_ed25519,password,env,known_hosts}` and
  `/usr/local/sbin/k3s-backup`. The script takes a fresh etcd snapshot, backs up
  `/var/lib/rancher/k3s/server/db/snapshots` and `/etc/rancher/k3s` with tags `etcd` and the hostname, and on
  opi-1 only runs `forget` (7 daily, 4 weekly, 3 monthly) and a 5 percent `check`.
- Installs `k3s-backup.timer` at 03:10, 03:20, 03:30 UTC for opi-1, -2, -3 respectively.
- Initialises the restic repository once if `restic snapshots` fails.

How to tell it worked: `sudo systemctl list-timers k3s-backup.timer` on each node; `sudo /usr/local/sbin/k3s-backup`
by hand and then `restic snapshots` via `scripts/backup-config.sh snapshots` from the control machine.

### Play 6, fetch kubeconfig (opi-1)

Reads `/etc/rancher/k3s/k3s.yaml`, replaces `127.0.0.1` with the LAN IP and writes `<repo>/kubeconfig`;
does the same with the Tailscale IP into `<repo>/kubeconfig-tailscale`. Both are mode 0600 and git-ignored.
The two local `copy` tasks set `ansible_become: false` as a var (5d). The play ends by printing
`kubectl get nodes -o wide` from opi-1.

How to tell it worked: `make nodes` from the repo shows three Ready nodes, using the `KUBECONFIG` mise exports.

### Where the reboots are

| When | Reboot | Condition |
|---|---|---|
| Play 1, `nvme` | yes, all nodes in parallel | only during the migration itself |
| Play 2, `kernel` | one node at a time | apt installed a kernel, or the running kernel lacks dm-crypt/iSCSI |
| Play 2, `common` (handler, flushed) | all nodes | zram config or `extraargs` changed |

None of these fire on a healthy re-run.

### Re-running

Every role is written to be idempotent, and the 2026-09-02 log confirms it for plays 1 and 2: 80 to 82 tasks
`ok`, 14 `changed` (all in the journald, fail2ban, login.defs and `updates` steps that had not run before).
Before the second run after hardening, delete the
`firstboot_ip` lines, otherwise plays 1 and 2 try `root` and fail.

### State of the 2026-09-02 run

The run in `bootstrap.log` got through plays 1 and 2 on all three boards, ran the `restart journald` and
`restart fail2ban` handlers, and then failed to open a TCP connection to `192.168.69.101:22` for play 3
(`UNREACHABLE`, "Connection timed out"). No `restart sshd` handler fired in that run, so the sshd drop-in
was already active from an earlier run. A timeout rather than a refusal means packets were dropped, which
points at nftables or a fail2ban ban rather than at sshd. Things to check from the serial console or over
Tailscale SSH: `sudo fail2ban-client status sshd`, `sudo nft list ruleset | grep -A5 f2b`,
`sudo nft list set inet host_fw lan`, and whether the control machine's address is inside
`hardening_lan_cidrs`. Plays 3 to 6 (k3s, backup, kubeconfig) are therefore still unproven on real hardware.

## 3. The custom kernel

### Why

Armbian ships the Orange Pi 4 Pro only as a community (`.csc`) board with the `vendor` kernel branch:
Linux `6.6.98-vendor-sun60iw2` from the orangepi-xunlong tree, config `linux-sun60iw2-vendor.config`.
That config has no `CONFIG_MD` (so no device-mapper at all), no `DM_CRYPT`, no `CRYPTO_XTS`, no
`ISCSI_TCP`/`SCSI_ISCSI_ATTRS` and no `CIFS`. Longhorn attaches volumes over iSCSI, the default
`longhorn-encrypted` StorageClass is LUKS (`aes-xts-plain64`), and Longhorn's backup target on the Storage
Box is SMB. All three are impossible on the stock kernel, and `roles/common` fails at
`modprobe dm_crypt`. Everything else (k3s, flannel, nftables, Tailscale, overlayfs, cgroups) works fine.

### What the build does

`scripts/build-kernel.sh` (`make kernel`):

- Clones `armbian/build` into `kernel/build/` at commit `8b778f3d82fb8dcfb3d663187de890a3700c8ee2`, which is
  the `BUILD_REPOSITORY_COMMIT` from `/etc/armbian-release` on the boards. Same source, same patches, same
  u-boot expectations as the image the boards were flashed with. There is no tag to pin to because there is no
  release for this board.
- Copies `kernel/userpatches/VERSION` (currently `26.08.0-k8s.1`) and `kernel/userpatches/extensions/*.sh`
  into the checkout.
- Runs `./compile.sh kernel BOARD=orangepi4pro BRANCH=vendor ENABLE_EXTENSIONS=k8s-storage,docker-dns[,headless-lowpower]
  PREFER_DOCKER=yes KERNEL_CONFIGURE=no`. The compiler runs in an `ubuntu-noble` container; the boards stay
  on Debian trixie.
- Collects `linux-{image,dtb,headers,libc-dev}-vendor-sun60iw2_26.08.0-k8s.1_arm64_*.deb` into
  `kernel/debs/`, extracts the effective `.config` next to them as `linux-sun60iw2-vendor.config`, and greps
  it for `BLK_DEV_DM`, `DM_CRYPT`, `CRYPTO_XTS`, `ISCSI_TCP`, `CIFS`.

The three extensions:

| Extension | Kind | Effect |
|---|---|---|
| `k8s-storage.sh` | kernel config, required | `MD=y`, `BLK_DEV_DM`, `DM_CRYPT`, `CRYPTO_XTS`, `CRYPTO_USER_API_SKCIPHER`, ARMv8 CE AES/SHA/GHASH, `SCSI_ISCSI_ATTRS`, `ISCSI_TCP`, `CIFS` as modules, plus `CIFS_XATTR/POSIX/DFS_UPCALL`. `olddefconfig` pulls in dependencies |
| `headless-lowpower.sh` | kernel config, on by default (`KERNEL_HEADLESS=1`) | Turns off DRM/HDMI, framebuffer and console logo, sound, the AIC8800 Wi-Fi and Bluetooth stack, cfg80211/mac80211, rfkill, camera and video input, LIRC, video codec, NPU, G2D, deinterlacer, touchscreen. These are built-in (`=y`) in the vendor config, so only the config can remove them. Result: no HDMI output at all, recovery is SSH or the debug UART (`console=ttyS0` stays on) |
| `docker-dns.sh` | host side only | Replaces the `--dns` arguments Armbian derives from the host's resolver with `KERNEL_DOCKER_DNS` (default `1.1.1.1 8.8.8.8`). Needed on WSL2 with Docker Desktop, see 5g |

Build with `KERNEL_HEADLESS=0 make kernel` if you ever need a screen on a board.

### Install and hold

`roles/kernel` (section 2) stages the debs, installs them only when the staged version differs from the
installed one, and `apt-mark hold`s `linux-image-`, `linux-dtb-` and `linux-headers-vendor-sun60iw2`.
Unattended-upgrades never considers them anyway (Armbian origin excluded), but `make os-upgrade` runs
`apt full-upgrade`, and the hold is what stops that from pulling in Armbian's next nightly kernel.

### Custom or stock? Same `uname -r`

Both kernels report `6.6.98-vendor-sun60iw2`. Do not use `uname` to tell them apart. Use one of:

```bash
zcat /proc/config.gz | grep -E '^CONFIG_(DM_CRYPT|ISCSI_TCP|CIFS)='   # =m on the custom kernel, absent on stock
dpkg-query -W linux-image-vendor-sun60iw2                              # 26.08.0-k8s.1 on the custom kernel
apt-mark showhold                                                      # the three linux-*-vendor-sun60iw2 packages
ls /boot/stock-kernel-backup                                           # exists once the custom kernel has been installed
```

### The stock kernel backup on the SD and how to recover

Before the first replacement the role copies `/boot/Image`, `uInitrd`, `vmlinuz-*`, `initrd.img-*`,
`System.map-*`, `config-*` and `dtb-*` into `/boot/stock-kernel-backup/`. Because `/boot` is the SD card's
`boot` directory bind-mounted over the NVMe root, that backup is physically on the SD, which is what makes it
useful when the board does not boot.

If a board will not boot the custom kernel:

1. Put the SD card in a PC and mount its ext4 partition.
2. Copy everything in `boot/stock-kernel-backup/` one level up into `boot/`, overwriting `Image`,
   `uInitrd`, `vmlinuz-*`, `initrd.img-*`, `dtb-*`. `boot/stock-kernel-backup/README.txt` says the same.
3. Boot. The board is now on the stock kernel with the custom packages still registered in dpkg. Once you are
   in, either fix the build and `make kernel-install LIMIT=<node>` again, or `apt-mark unhold` the three
   packages and reinstall Armbian's `linux-image-vendor-sun60iw2` from its repository.

`/boot/ROLLBACK.txt` (from the `nvme` role) covers the other failure, an unbootable NVMe root: edit
`rootdev=` in `armbianEnv.txt` back to the SD's UUID.

### Canary and upgrade path

`make kernel-install LIMIT=opi-2` runs `ansible/kernel.yml` on one node. It is the same `kernel` role wrapped
in a `serial: 1` play that:

- checks `/var/lib/rancher/k3s/server/cred` to see whether k3s exists on the node,
- if so, `kubectl drain` from the `k3s_init` node first, and after the role `wait_for` 6443, `kubectl uncordon`
  and polls until Ready,
- if not (fresh bootstrap), just installs and reboots.

To ship a new kernel: bump `kernel/userpatches/VERSION` to `26.08.0-k8s.<N+1>`, optionally move
`ARMBIAN_COMMIT` in `scripts/build-kernel.sh`, `make kernel`, copy `kernel/debs/` to the control machine,
`make kernel-install LIMIT=opi-2`, check it comes back (`make nodes`, the config.gz grep above), then
`make kernel-install` for the rest. Because `roles/kernel` is also in `site.yml`, a later `make bootstrap`
would install the new debs too, but in parallel with only the reboot throttled, so prefer `kernel-install`
on a live cluster.

## 4. After bootstrap: `make argocd`

`make argocd` = `cd tofu && tofu init && tofu apply`, then `scripts/backup-config.sh backup` (errors ignored).
It needs `<repo>/kubeconfig` from play 6, `tofu/terraform.tfvars` (copied from the example: `git_repo_url`,
`storagebox_user`, `storagebox_password`, optional deploy key, Grafana password and Tailscale OAuth client),
and `BACKUP_KEY`, which the Makefile exports as `TF_VAR_backup_key`.

State lives in the cluster: kubernetes backend, Secret `tfstate-default-opi-k8s` in `kube-system`, encrypted
by OpenTofu's `pbkdf2` + `aes_gcm` state encryption with `backup_key` (`enforced = true`, so it will not
write plaintext state). A fresh cluster means empty state, which is the intended DR behaviour.

What Tofu creates, in dependency order:

| Resource | File | Notes |
|---|---|---|
| Namespace `argocd`, optional repo Secret `repo-opi-k8s` | `tofu/argocd.tf` | Secret only when `git_ssh_private_key_file` is set |
| Helm release `argocd` (argo-cd chart 10.4.2) | `tofu/argocd.tf` | Values = `gitops/argocd/values.yaml` + `root-app.yaml.tftpl`, which adds the `root` Application as an `extraObjects` entry. `ignore_changes = [version, values]` afterwards |
| Namespace `monitoring` (PSA privileged), Secret `grafana-admin` | `tofu/secrets.tf` | Password from tfvars or random; `make grafana-password` |
| Namespace `tailscale` (privileged), Secret `operator-oauth` | `tofu/secrets.tf` | Only when `tailscale_oauth_client_id` is set |
| Namespace `longhorn-system` (privileged), Secrets `longhorn-crypto` (LUKS key = `backup_key`) and `longhorn-backup-s3` (S3 endpoint + bucket-scoped key pair; the target bucket/region/path is in `gitops/longhorn/values.yaml`) | `tofu/longhorn.tf` | Storage Box SMB needs the password, not a key |

Then ArgoCD takes over. The `root` Application points at `gitops/bootstrap` in `git_repo_url` on
`git_revision`, a Helm chart whose templates are one Application per component, ordered by sync wave:

| Wave | Application | Source | Namespace |
|---|---|---|---|
| -10 | `argocd` | argo-cd chart 10.4.2 + `gitops/argocd/values.yaml` | argocd (adopts Tofu's release, manages itself from now on) |
| -5 | `tailscale-operator` | chart 1.102.3 + `gitops/tailscale/` | tailscale, only if `tailscale.enabled` in `gitops/bootstrap/values.yaml` |
| -3 | `longhorn` | chart 1.12.0 + `gitops/longhorn/` (StorageClasses `longhorn-encrypted` default and `longhorn`, RecurringJobs) | longhorn-system |
| 0 | `monitoring` | kube-prometheus-stack 88.3.0 + `gitops/monitoring/` | monitoring, toggled by `monitoring.enabled` |
| 5 | `kured` | chart 6.0.0 + `gitops/kured/` | kured |
| 5 | `system-upgrade` | kustomize of SUC v0.18.0 + `plan-k3s.yaml` | system-upgrade |

`make apps` watches them go Synced/Healthy; `make argocd-password` prints the initial admin password. The
first sync is slow on the boards because the Prometheus CRDs are large.

Where things land locally: `kubeconfig` and `kubeconfig-tailscale` at the repo root (git-ignored),
`ansible/secrets/` (root passwords, Storage Box key), `tofu/terraform.tfvars`, `kernel/debs/`. All of these
except the root passwords are what `scripts/backup-config.sh backup` pushes to the restic repository on the
Storage Box under tag `laptop-config`, keeping the last 10 snapshots.

## 5. Things that bit us on real hardware

### a. Armbian has no stable image for this board

Symptom: the "stable releases only" rule cannot be met for the OS. The download page offers only
`26.11.0-trunk.x` nightlies (Debian 13) with the `vendor` kernel branch.
Cause: in `armbian/build` the Orange Pi 4 Pro is a `.csc` community-supported board, which is excluded from
release builds.
Fix: accepted exception. The kernel rebuild is pinned to the exact `armbian/build` commit the boards' image
came from (`/etc/armbian-release`, `BUILD_REPOSITORY_COMMIT`) instead of a tag, so at least the kernel is
reproducible.

### b. `stdout_callback = yaml` is gone

Symptom: `ansible-playbook` refuses to start, complaining about the `yaml` callback.
Cause: the `community.general.yaml` stdout callback was removed in community.general 12 (bundled with
Ansible 14). The replacement is the built-in default callback with `callback_result_format = yaml`.
A second trap while fixing it: Ansible's ini parser keeps an inline `# comment` as part of the value, so
`callback_result_format = yaml  # readable` sets the format to `yaml  # readable` and still fails.
Fix: `ansible/ansible.cfg` now has `callback_result_format = yaml` on its own line with the comment above it.

### c. mise needs to be told where `ansible-playbook` lives

Symptom: after `make deps`, `ansible` exists but `ansible-playbook` does not, or only `ansible-core` is
installed and every role fails on missing `community.general` / `ansible.posix` / `community.crypto`.
Cause: the pipx backend uses uv, and uv only exposes the console scripts of the named package. The `ansible`
community package bundles the collections but its executables belong to the `ansible-core` dependency.
Installing `ansible-core` instead gives the executables and no collections.
Fix: `mise.toml` pins
`"pipx:ansible" = { version = "14.3.1", uvx_args = "--with-executables-from ansible-core" }`
with `settings.pipx.uvx = true`.

### d. Inventory `ansible_become: true` beats a task's `become: false`

Symptom: tasks delegated to `localhost` (finding the kernel debs, writing the kubeconfigs) try `sudo` on the
control machine and either prompt or fail.
Cause: `ansible_become` set as an inventory variable outranks the `become` keyword on a task.
Fix: those tasks now carry `vars: { ansible_become: false }` in addition to `become: false`
(`roles/kernel/tasks/main.yml`, `site.yml` play 6). The two `delegate_to: localhost` tasks in
`roles/backup` still have only the keyword and have not run yet; expect the same symptom there.

### e. `deb822_repository` needs `python3-debian` on the node

Symptom: the Tailscale role fails at "Add Tailscale apt repository" with a missing Python module.
Cause: `ansible.builtin.deb822_repository` imports `debian.deb822` on the target.
Fix: `python3-debian` added to `base_packages` in `group_vars/all.yml`; `common` runs before `tailscale`.

### f. `/etc/systemd/journald.conf.d` does not exist on minimal images

Symptom: hardening fails copying `journald.conf.d/size.conf`, "destination directory does not exist".
Cause: Armbian minimal images ship no drop-in directory for journald.
Fix: a `file: state=directory` task before the copy. This is one of the 14 changes in the 2026-09-02 log.

### g. The Armbian build container cannot resolve names on WSL2

Symptom: `make kernel` fails early with apt "Temporary failure resolving" inside the container.
Cause: Armbian copies the host's nameservers into `docker run --dns ...`. Under WSL2 with Docker Desktop the
host resolver is `10.255.255.254`, which containers cannot reach.
Fix: `kernel/userpatches/extensions/docker-dns.sh` strips those `--dns` arguments and adds
`KERNEL_DOCKER_DNS` (default `1.1.1.1 8.8.8.8`). `KERNEL_DOCKER_DNS=""` keeps Armbian's behaviour.

### h. SSH "hangs" on WSL2 because the Windows agent wants approval

Symptom: `ssh` stalls right after "Server accepts key" / "signing using ssh-ed25519"; `make key` never
returns; Ansible reports hosts UNREACHABLE while `nc <host> 22` shows a banner.
Cause: `SSH_AUTH_SOCK` in WSL is a socat/npiperelay bridge to the Windows OpenSSH agent. `ssh-add -L` answers
immediately, but a sign request blocks until the prompt on the Windows side is approved.
Fix: approve or unlock on Windows. Diagnose with
`printf x | timeout 5 ssh-keygen -Y sign -n test -f ~/.ssh/id_ed25519_cluster.pub`; exit code 124 means the
agent is waiting on you. Wrap probes in `timeout`.

### i. The kernel role rebooted every run

Symptom: every `make bootstrap` rebooted all three boards at the kernel role, even with the custom kernel
already running.
Cause: the running-kernel check was `set -o pipefail; zcat /proc/config.gz | grep -q ...`. `grep -q` exits on
the first match and closes the pipe, `zcat` dies of SIGPIPE, `pipefail` turns that into a non-zero status,
and the reboot condition `kernel_running_ok.rc != 0` was always true.
Fix: read the config into a variable once and grep the variable (`roles/kernel/tasks/main.yml`). The
2026-09-02 log shows the reboot task skipped on all nodes.

### Open when this was written

The k3s-init play could not reach opi-1 on port 22 (section 2, "State of the 2026-09-02 run"). Not
diagnosed yet; start with fail2ban and the `/24` versus `/22` LAN definition.

## 6. Day-2 pointers

| Task | Command | Notes |
|---|---|---|
| Re-run bootstrap after hardening | `make bootstrap` | Remove every `firstboot_ip` first. The hardening role switches Ansible to `ops` for the rest of that run and all later runs; a host with `firstboot_ip` is treated as fresh (root, default password) |
| Full OS upgrade including Armbian packages | `make os-upgrade` | `ansible/upgrade-os.yml`: drain, `apt full-upgrade`, reboot if `/var/run/reboot-required`, uncordon, wait Ready, 60 s pause, next node. The held kernel packages are skipped |
| New custom kernel | `make kernel` then `make kernel-install LIMIT=opi-2`, then `make kernel-install` | Section 3. Bump `kernel/userpatches/VERSION` first |
| Save laptop-side secrets | `make backup-config` | Also runs at the end of every `make argocd`. `make backup-restore-config` pulls them back |
| Inspect Tofu state | `make state-show` | Secret timestamp + `tofu state list` |
| Check the cluster | `make nodes`, `make apps` | `kubectl get nodes -o wide` and the ArgoCD Applications |

Disaster recovery order (from `CLAUDE.md`, full commands in `README.md`):

1. On the control machine: repo, `make deps`, SSH key in the agent, `STORAGEBOX_USER`/`HOST` set,
   `make backup-restore-config` to get `.env`, tfvars, kubeconfigs, `ansible/secrets/` and `kernel/debs/` back.
2. `make bootstrap` (the restic repository already exists on the box and is reused).
3. Set `monitoring.enabled: false` in `gitops/bootstrap/values.yaml`, push, `make argocd`.
4. Wait for `kubectl -n longhorn-system get backupvolumes` to list the volumes.
5. `make restore-volumes` (`DRY_RUN=1` first), watch `volumes.longhorn.io` until `detached`.
6. Revert the values change, push, `make apps`.
