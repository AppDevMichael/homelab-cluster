---
name: homelab-iac
description: "Production-grade discipline for the opi-k8s homelab repo (Ansible → k3s on Orange Pis, OpenTofu bootstrap, ArgoCD GitOps, Longhorn, Tailscale, restic/Hetzner backups). Use this skill for ANY change in this repo — adding or upgrading a chart, tool, or k3s version; editing Ansible roles, Tofu, gitops values, scripts, Makefile, or docs; investigating a failed sync or playbook; answering 'is X up to date'; or before declaring any task finished. It enforces stable-only exact version pins verified on release pages, no-secrets-in-git, tools-only-if-used, and a mandatory pre-finish verification sweep. Trigger even for small edits: most past mistakes in this repo were small edits."
---

# homelab-iac

This repo is the owner's production homelab. "Production grade" here means: every version is a
verified GA release, every change is reproducible from git, nothing secret is committed, and every
edit is checked before it is called done. The mistakes this skill exists to prevent all actually
happened while building the repo: a pre-release OpenTofu got pinned from a search snippet, tool
versions went stale, a CLI nobody used was added to `mise.toml`, a script needed `jq` that wasn't
installed, a brace-expansion failure left a stray `{ansible/` directory in the tree, a partial playbook run
rendered k3s's config without facts another role sets and restarted k3s on every node, an inventory-level
`ansible_become: true` made laptop-side tasks sudo, and a `--dry-run` that waits on the apt lock hung a run for good.

Read `CLAUDE.md` at the repo root first if you haven't this session — it holds the architecture,
layout, and the list of untested/fragile spots.

## 1. Version pinning protocol

Pinning a version is a claim that a specific artifact exists and is stable. Prove it.

1. **Open the actual release page** (GitHub releases, `index.yaml` of the Helm repo, PyPI release
   list). A search result, blog post, or changelog excerpt is not evidence — that is exactly how
   OpenTofu 1.13 (unreleased) got pinned instead of 1.12.6. See `references/version-sources.md`
   for the canonical page per component.
2. **Reject anything with** `rc`, `beta`, `alpha`, `dev`, `nightly`, `pre`, or a GitHub
   "Pre-release" badge. If the newest entry is a pre-release, take the newest one that isn't.
3. **Pin exactly** (`1.12.6`, not `1.12`, not `~> 1.12`). The only allowed exceptions are tools
   used solely by `make lint`, which may use a stable-only prefix — and say so in a comment.
4. **Match coupled versions**: kubectl minor = k3s minor; the system-upgrade Plan channel
   (`gitops/system-upgrade/plan-k3s.yaml`) = the k3s minor in `ansible/group_vars/all.yml`. The argo-cd chart is
   pinned once, in `gitops/bootstrap/templates/argocd.yaml` (Tofu reads it from there); `argocd_apps_chart_version`
   in `tofu/variables.tf` is its own exact pin.
5. **Check chart values keys after a major chart bump**: run
   `helm show values <repo>/<chart> --version <new>` and diff the keys used in the corresponding
   `gitops/<app>/values.yaml`. Charts rename keys between majors and ArgoCD will happily apply a
   values file whose keys are silently ignored.
6. **Record the verification date** in the README version table and in `CLAUDE.md`.

## 2. Tool discipline (`mise.toml`)

A tool goes in `mise.toml` only if something in the repo invokes it. Before adding one, grep for it
in `Makefile` and `scripts/`; if there's no hit, don't add it. Before removing one, grep too — `jq`
was missing while `scripts/restore-longhorn-volumes.sh` called it eight times. Run
`scripts/verify-repo.sh` (section 5) — it does this comparison automatically.

Use the `ansible` community package, not `ansible-core` + galaxy: one install, no collection step.

## 3. Secrets

Secrets are created by OpenTofu (`tofu/secrets.tf`, `tofu/longhorn.tf`, `tofu/argocd.tf`) from
`terraform.tfvars`/env and referenced **by name** from chart values (`existingSecret`,
`operator-oauth`, `longhorn-crypto`, `longhorn-backup-s3`). Longhorn backups go to an S3 bucket (B2) —
the ISP blocks SMB to the Storage Box; restic uses the box over SFTP:23 with relative repo paths. Never write a password, token, key,
or kubeconfig into anything under `gitops/`, `ansible/roles`, or docs. If a new app needs a
secret: add it to Tofu, reference it by name, add the namespace's PSA label there if the app needs
privileged pods.

The backup passphrase is derived from the owner's SSH agent by `scripts/backup-key.sh`. Never
change the message or namespace string in that script — it would silently change the key and orphan
every backup.

## 4. Change hygiene

- One change, one reason. Don't "tidy" unrelated files in the same edit.
- Every behaviour change updates `README.md` (runbooks + version table) and, if it affects
  architecture or risk, `CLAUDE.md`.
- Anything you write but cannot execute goes in `CLAUDE.md` → "Known untested / fragile spots",
  ranked. Don't let unexecuted code look tested.
- New ArgoCD app: copy `gitops/bootstrap/templates/monitoring.yaml` (multi-source: chart +
  `$values` ref + optional manifests path), reuse the `bootstrap.syncPolicy` helper, pick a
  sync-wave (storage −3, operators −5, apps 0, maintenance 5), add `gitops/<app>/values.yaml`.
- Ansible: FQCN modules, `no_log: true` on anything touching secrets, idempotent — a second run
  must report zero changes. Canary with `-l opi-2` (and `--check --diff` for anything that can restart a
  service) before all three; this is a production cluster.
- Never `--start-at-task` into a play whose templates use facts set by an earlier role unless that role
  gathers them itself (the k3s role does, for Tailscale SANs). A missing fact = a changed render = a restart.
- Task-level `become: false` loses to an inventory `ansible_become` var; keep `ansible_become` on the
  `k3s_cluster` group only, never on `all`.
- No apostrophes in comments inside `shell:` blocks or free-form `command:` strings — Ansible's argument
  splitter treats them as quotes. No `set -o pipefail` with `cmd | grep -q` (early exit → broken pipe → rc 141).
- Storage Box: restricted shell (only file commands, no `true`, no `&&`), sub-account SFTP is chrooted
  (relative paths), always `-o IdentitiesOnly=yes` (an agent full of keys trips MaxAuthTries).
- Shell: `set -euo pipefail`; the sandbox `sh` has no brace expansion — use explicit `mkdir -p`
  per path, never `{a,b}`.

## 5. Before saying "done" — mandatory

Run the bundled sweep and fix everything it reports:

```bash
.claude/skills/homelab-iac/scripts/verify-repo.sh
```

It checks: YAML parses; `bash -n` on scripts; stray/empty/brace-named dirs; roles ↔ `site.yml`;
role templates/files exist; `var.*` ↔ `variables.tf`; Tofu resource cross-refs; `.Values.*` ↔
`bootstrap/values.yaml`; `make` targets in docs exist; mise tools ↔ tools actually invoked;
secret names consistent between Tofu and gitops (and no CIFS remnants); PSA labels on namespaces that need
them; coupled versions (kubectl/k3s, Plan channel, single argo-cd pin) agree; no obvious secret literals in
git-tracked files. The same script runs in CI (`.github/workflows/lint.yml`) on every PR.

When the cluster is reachable, also run `make check` (nodes, apps, pods, Longhorn + backup target, restic
snapshot age, backup timers) after any change that touched the nodes or gitops.

When network is available also run `make lint` (ansible-lint, `tofu validate`, `helm lint`,
`kustomize build`) and `helm template` each app with its values file.

Then, in your reply, state plainly which of these you ran and which you could not.

## 6. When investigating failures

- ArgoCD app OutOfSync/Degraded: `kubectl -n argocd get app <name> -o yaml | yq .status.conditions`
  first; the common causes in this repo are a renamed values key, a missing PSA label, or a CRD
  too large for client-side apply (ServerSideApply is already on — check it's still there).
- Playbook failure on first boot: check `ansible/secrets/root_password_<node>` exists (firstboot
  ran) and whether the node moved to its static IP; re-runs are safe.
- Longhorn backup target: `kubectl -n longhorn-system get backuptargets.longhorn.io default -o yaml`
  (S3/B2: endpoint + keys in the `longhorn-backup-s3` Secret, bucket/region/path in `gitops/longhorn/values.yaml`).
- A UI giving "bad gateway" / "no available server" through Traefik = the pod is not Ready; check
  `kubectl get events` for OOMKilled/probe failures before touching the ingress.
- The boards boot from SPI with no SD card; `findmnt -no SOURCE /` shows nvme. The custom kernel and the
  stock one share `uname -r` — tell them apart with `zcat /proc/config.gz | grep DM_CRYPT`.
- Dependency updates: Renovate (`renovate.json`) opens PRs + a Dependency Dashboard issue on GitHub; CI
  lints every PR. Verify a proposed version on its release page before merging.
