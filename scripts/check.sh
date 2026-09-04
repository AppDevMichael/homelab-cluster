#!/usr/bin/env bash
# `make check` — is the cluster healthy right now? Read-only. Exit 1 if anything is off.
#   nodes Ready · ArgoCD apps Synced+Healthy · no pod stuck · Longhorn volumes healthy + backup target available
#   · restic snapshot on the Storage Box < 24 h · k3s backup timers armed
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0; ok() { printf '  ok   %s\n' "$*"; }; bad() { printf '  FAIL %s\n' "$*"; fail=1; }

echo "nodes"
nodes=$(kubectl get nodes --no-headers)
notready=$(awk '$2!="Ready"' <<< "$nodes"); [[ -z $notready ]] && ok "$(wc -l <<< "$nodes") nodes Ready" || bad "not Ready: $(awk '{print $1}' <<< "$notready" | tr '\n' ' ')"

echo "argocd"
apps=$(kubectl -n argocd get applications --no-headers 2>/dev/null || true)
[[ -n $apps ]] || bad "no Applications (run make argocd)"
badapps=$(awk '$2!="Synced" || $3!="Healthy"' <<< "$apps"); [[ -z $badapps ]] && ok "$(wc -l <<< "$apps") apps Synced+Healthy" || bad "$(awk '{print $1"="$2"/"$3}' <<< "$badapps" | tr '\n' ' ')"

echo "pods"
stuck=$(kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed" {print $1"/"$2"="$4}')
[[ -z $stuck ]] && ok "all pods Running/Completed" || bad "$(tr '\n' ' ' <<< "$stuck")"
restarting=$(kubectl get pods -A --no-headers | awk '$5>5 {print $1"/"$2"("$5")"}')
[[ -z $restarting ]] && ok "no pod with >5 restarts" || bad "restart loops: $(tr '\n' ' ' <<< "$restarting")"

echo "longhorn"
vols=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers 2>/dev/null || true)
unhealthy=$(awk '$3=="attached" && $4!="healthy" {print $1"="$4}' <<< "$vols"); [[ -z $unhealthy ]] && ok "$(grep -c . <<< "$vols") volumes, attached ones healthy" || bad "$(tr '\n' ' ' <<< "$unhealthy")"
bt=$(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}' 2>/dev/null || echo "?")
[[ $bt == "true" ]] && ok "backup target available" || bad "backup target available=$bt"

echo "restic (Storage Box)"
export RESTIC_PASSWORD="${BACKUP_KEY:?export BACKUP_KEY=\$(scripts/backup-key.sh)}"
export RESTIC_REPOSITORY="sftp:${STORAGEBOX_USER}@${STORAGEBOX_HOST}:opi-k8s/restic"
SSH_CMD="ssh -p 23 -i ansible/secrets/storagebox_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new ${STORAGEBOX_USER}@${STORAGEBOX_HOST} -s sftp"
latest=$(restic -o "sftp.command=$SSH_CMD" snapshots --tag etcd --json 2>/dev/null | python3 -c 'import sys,json,datetime; s=json.load(sys.stdin); print(max(x["time"] for x in s) if s else "")' || true)
if [[ -n $latest ]]; then
  age_h=$(python3 -c "import datetime,sys; t=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')); print(int((datetime.datetime.now(datetime.timezone.utc)-t).total_seconds()//3600))" "$latest")
  (( age_h < 24 )) && ok "latest etcd snapshot ${age_h}h old" || bad "latest etcd snapshot ${age_h}h old"
else bad "no etcd snapshots found (or Storage Box unreachable)"; fi

echo "backup timers + clocks"
for n in $(awk '{print $1}' <<< "$nodes"); do
  r=$(ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "ops@$n" 'echo "$(systemctl is-active k3s-backup.timer) $(chronyc tracking | awk -F: "/System time/{print \$2}" | awk "{print \$1}")"' 2>/dev/null || echo "unreachable 0")
  t=${r%% *}; off=${r##* }
  [[ $t == active ]] && ok "$n k3s-backup.timer active" || bad "$n k3s-backup.timer $t"
  awk -v o="$off" 'BEGIN{exit !(o<0.1)}' && ok "$n clock offset ${off}s" || bad "$n clock offset ${off}s (chrony)"
done

(( fail == 0 )) && echo "ALL GOOD" || { echo "PROBLEMS FOUND"; exit 1; }
