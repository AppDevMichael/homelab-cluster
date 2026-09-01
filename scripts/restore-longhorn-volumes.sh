#!/usr/bin/env bash
# Disaster recovery: recreate every volume from its latest backup on the Storage Box and re-create the
# PV/PVC with the ORIGINAL names/namespaces, so when ArgoCD deploys the apps they bind to their old data.
#
# Run AFTER Longhorn is up and has synced the backup target (kubectl -n longhorn-system get backupvolumes)
# and BEFORE enabling the data-bearing apps (monitoring) in gitops/bootstrap/values.yaml.
set -euo pipefail
NS=longhorn-system
DRY="${DRY_RUN:-}"

bvs=$(kubectl -n $NS get backupvolumes.longhorn.io -o json)
count=$(jq '.items | length' <<<"$bvs")
[[ "$count" -gt 0 ]] || { echo "no backup volumes found — is the backup target set and synced?"; exit 1; }
echo "found $count backup volume(s)"

jq -c '.items[]' <<<"$bvs" | while read -r bv; do
  vol=$(jq -r '.status.volumeName // .metadata.name' <<<"$bv")
  last=$(jq -r '.status.lastBackupName // empty' <<<"$bv")
  ks=$(jq -r '.status.labels.KubernetesStatus // empty' <<<"$bv")
  [[ -n "$last" && -n "$ks" ]] || { echo "skip $vol (no backup or no k8s metadata)"; continue; }
  pvc=$(jq -r '.pvcName' <<<"$ks"); pvcns=$(jq -r '.namespace' <<<"$ks")
  size=$(jq -r '.status.size' <<<"$bv")
  sc=$(kubectl -n $NS get backup "$last" -o jsonpath='{.status.labels.longhorn\.io/storage-class}' 2>/dev/null || true)
  sc=${sc:-longhorn-encrypted}
  target=$(kubectl -n $NS get backuptarget default -o jsonpath='{.spec.backupTargetURL}')
  echo "→ $vol  ← $last   ($pvcns/$pvc, $sc)"
  [[ -n "$DRY" ]] && continue

  cat <<YAML | kubectl apply -f -
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata: { name: $vol, namespace: $NS }
spec:
  fromBackup: "${target}?backup=${last}&volume=${vol}"
  numberOfReplicas: 2
  size: "$size"
  encrypted: $([[ "$sc" == *encrypted* ]] && echo true || echo false)
  frontend: blockdev
---
apiVersion: v1
kind: PersistentVolume
metadata: { name: $vol }
spec:
  capacity: { storage: "$size" }
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: $sc
  claimRef: { name: $pvc, namespace: $pvcns }
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: $vol
$([[ "$sc" == *encrypted* ]] && cat <<X
    nodeStageSecretRef: { name: longhorn-crypto, namespace: $NS }
    nodePublishSecretRef: { name: longhorn-crypto, namespace: $NS }
    volumeAttributes: { encrypted: "true" }
X
)
---
apiVersion: v1
kind: Namespace
metadata: { name: $pvcns }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $pvc, namespace: $pvcns }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $sc
  volumeName: $vol
  resources: { requests: { storage: "$size" } }
YAML
done
echo "done. watch: kubectl -n $NS get volumes.longhorn.io -w   (state → detached = restored)"
