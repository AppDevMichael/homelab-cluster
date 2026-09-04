#!/usr/bin/env bash
# Deterministic pre-finish sweep for the opi-k8s repo. Exit non-zero on any finding.
set -uo pipefail
# repo root = four levels up from this script (.claude/skills/homelab-iac/scripts), regardless of cwd
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)" || exit 2
FAILFILE=$(mktemp); trap 'rm -f "$FAILFILE"' EXIT
# bad() may be called inside pipelines/subshells, so it records the failure in a file, not a variable
bad(){ echo "FAIL: $*"; echo 1 >> "$FAILFILE"; }; ok(){ echo "ok   $*"; }

echo "== stray / brace / empty directories"
find . -type d \( -name '*{*' -o -name '*}*' \) -not -path './.git/*' | while read -r d; do bad "brace-named dir: $d"; done
find . -type d -empty -not -path './.git/*' -not -path './ansible/secrets' | while read -r d; do git check-ignore -q "$d" || bad "empty dir: $d"; done
ok "tree"

echo "== YAML parses"
python3 - <<'PY'
import yaml,glob,sys
bad=0
for f in glob.glob('**/*.y*ml',recursive=True):
    if '/templates/' in f or f.startswith('.git/'): continue
    try: list(yaml.safe_load_all(open(f)))
    except Exception as e: print(f"FAIL: {f}: {e}"); bad=1
sys.exit(bad)
PY
[ $? -eq 0 ] || bad "YAML parse errors above"

echo "== shell syntax"
for s in scripts/*.sh .claude/skills/*/scripts/*.sh; do bash -n "$s" && [ -x "$s" ] || bad "$s (syntax or not executable)"; done

echo "== ansible roles <-> site.yml"
for r in $(grep -oE '^\s+- (\{ role: )?[a-z0-9_]+' ansible/site.yml | grep -oE '[a-z0-9_]+$' | sort -u | grep -vE '^(role|name|common|ansible)$'); do [ -d "ansible/roles/$r" ] || bad "site.yml references missing role $r"; done
[ -d ansible/roles/common ] || bad "missing role common"
for d in ansible/roles/*/; do r=$(basename "$d"); grep -rqE "(- $r\$|role: $r|name: $r$|name: $r[, }])" ansible/*.yml ansible/roles/*/tasks/*.yml || bad "role $r not used anywhere"; done
grep -rhoE "(src|template): [A-Za-z0-9_./-]+\.(j2|yaml|yml|sh)" ansible/roles/*/tasks/*.yml | awk '{print $2}' | sort -u | while read -r f; do
  find ansible/roles -path "*/templates/$f" -o -path "*/files/$f" | grep -q . || bad "role file missing: $f"; done

echo "== tofu references"
for v in $(grep -rhoE 'var\.[a-z_0-9]+' tofu/*.tf tofu/*.tftpl | sort -u | cut -d. -f2); do grep -q "variable \"$v\"" tofu/variables.tf || bad "undeclared var.$v"; done
for v in $(grep -oE 'variable "[a-z_0-9]+"' tofu/variables.tf | cut -d'"' -f2); do grep -rq "var\.$v\b" tofu/*.tf tofu/*.tftpl || bad "unused variable $v"; done
for r in $(grep -rhoE '(kubernetes_[a-z_0-9]+|helm_release|random_password)\.[a-z_]+' tofu/*.tf | sort -u); do
  t=${r%%.*}; n=${r##*.}; grep -qE "resource \"$t\" \"$n\"" tofu/*.tf || bad "unresolved resource ref $r"; done

echo "== helm bootstrap values"
for v in $(grep -rhoE '\.Values\.[a-z.]+' gitops/bootstrap/templates | sort -u | sed 's/^\.Values\.//'); do
  python3 -c "
import yaml; d=yaml.safe_load(open('gitops/bootstrap/values.yaml'))
for k in '$v'.split('.'): d=d[k]" 2>/dev/null || bad "bootstrap values missing: $v"; done

echo "== make targets referenced in docs"
for t in $(grep -oE 'make [a-z-]+' README.md CLAUDE.md | awk '{print $2}' | sort -u | grep -vE '^(-s)$'); do grep -qE "^$t:" Makefile || bad "docs reference missing target: make $t"; done

echo "== mise tools <-> tools invoked"
# a tool counts as invoked only in command position: line start, after $( | ; && ||, or after 'exec'/'command -v'
TOOLS='tofu|ansible-playbook|ansible-lint|kubectl|helm|kustomize|restic|jq|yq|argocd|k9s|sops|age'
invoked=$(grep -rhoE "(^|[|;&({]|\\$\\(|\\bexec |command -v )[[:space:]]*($TOOLS)([[:space:]]|$)" Makefile scripts/*.sh .github/workflows/*.yml | grep -oE "($TOOLS)[[:space:]]*$" | tr -d ' \t' | sort -u)
declare -A map=([tofu]=opentofu [ansible-playbook]=ansible [ansible-lint]=ansible-lint [kubectl]=kubectl [helm]=helm [kustomize]=kustomize [restic]=restic [jq]=jq [yq]=yq [argocd]=argocd [k9s]=k9s [sops]=sops [age]=age)
for i in $invoked; do grep -qE "^\"?(pipx:)?${map[$i]}\"? *=" mise.toml || bad "tool '$i' is invoked but not in mise.toml"; done
for t in $(sed -n '/^\[tools\]/,/^\[/p' mise.toml | grep -oE '^"?(pipx:)?[a-z0-9-]+"? *=' | sed -E 's/"//g; s/ *=//; s/pipx://'); do
  case $t in opentofu) i=tofu;; ansible) i=ansible-playbook;; uv) continue;; *) i=$t;; esac   # uv = backend for the pipx: tools
  echo "$invoked" | grep -qx "$i" || bad "mise.toml installs '$t' but nothing invokes it"; done

echo "== secret names consistent"
for n in grafana-admin operator-oauth longhorn-crypto longhorn-backup-s3; do
  grep -q "\"$n\"" tofu/*.tf || bad "secret $n not created in tofu"; grep -rq "$n" gitops || bad "secret $n not referenced in gitops"; done
grep -rq 'longhorn-backup-cifs\|CIFS_' tofu gitops && bad "CIFS remnants (backups are S3)"

echo "== PSA privileged labels present for privileged namespaces"
for ns in monitoring tailscale longhorn-system; do grep -A4 "name = \"$ns\"" tofu/*.tf | grep -q privileged || bad "ns $ns lacks privileged label in tofu"; done
grep -rq privileged gitops/kured/manifests/ || bad "kured ns manifest lacks privileged label"
grep -q privileged gitops/system-upgrade/kustomization.yaml || bad "system-upgrade ns lacks privileged patch"

echo "== coupled versions"
k3s=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' ansible/group_vars/all.yml | head -1); kminor=${k3s%.*}
kubectl=$(grep -oE '^kubectl *= *"[0-9.]+"' mise.toml | grep -oE '[0-9.]+')
[ "v${kubectl%.*}" = "$kminor" ] || bad "kubectl $kubectl vs k3s $k3s minor mismatch"
grep -q "channels/$kminor\$" gitops/system-upgrade/plan-k3s.yaml || bad "SUC plan channel != k3s minor $kminor"
grep -q 'regex("targetRevision: (\[0-9.\]+)"' tofu/argocd.tf || bad "tofu/argocd.tf must derive the argo-cd chart version from gitops/bootstrap/templates/argocd.yaml (single pin)"
grep -A3 'argocd_apps_chart_version' tofu/variables.tf | grep -qE 'default *= *"[0-9]+\.[0-9]+\.[0-9]+"' || bad "argocd_apps_chart_version must be an exact pin"

echo "== no pre-release versions pinned"
grep -rnE '(version|targetRevision|releases/download/v[0-9.]+|^[a-z:"-]+ *= *")[^#]*[0-9](-|\.)?(rc|beta|alpha|nightly|dev|pre)[.-]?[0-9]*' mise.toml tofu/versions.tf tofu/variables.tf ansible/group_vars/all.yml gitops/bootstrap/templates gitops/system-upgrade/kustomization.yaml | grep -viE 'apiVersion|required_version|codename=|Debian-Security|dev\.|/opi-k8s/' | while read -r l; do bad "pre-release-looking pin: $l"; done

echo "== secret-looking literals in tracked files"
grep -rnE '(tskey-(auth|client)-[A-Za-z0-9]{6,}|BEGIN (OPENSSH|RSA) PRIVATE KEY|AWS_SECRET_ACCESS_KEY *[:=] *"?[A-Za-z0-9/+]{20,})' --include='*.yaml' --include='*.yml' --include='*.tf' --include='*.md' --include='*.j2' . 2>/dev/null | grep -v '\.env\.example' | while read -r l; do bad "possible secret: $l"; done

[ ! -s "$FAILFILE" ] && echo "ALL CHECKS PASSED" || { echo "$(wc -l < "$FAILFILE") FINDING(S) ABOVE — fix before finishing"; exit 1; }
