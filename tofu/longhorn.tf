# Longhorn namespace + the two secrets it needs (LUKS key, S3 backup credentials). Longhorn itself is deployed by ArgoCD (gitops/longhorn).

resource "kubernetes_namespace_v1" "longhorn" {
  metadata {
    name = "longhorn-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

# LUKS passphrase for encrypted volumes. Same key as the restic repo (derived from your SSH agent).
resource "kubernetes_secret_v1" "longhorn_crypto" {
  metadata {
    name      = "longhorn-crypto"
    namespace = kubernetes_namespace_v1.longhorn.metadata[0].name
  }
  data = {
    CRYPTO_KEY_VALUE    = var.backup_key
    CRYPTO_KEY_PROVIDER = "secret"
    CRYPTO_KEY_CIPHER   = "aes-xts-plain64"
    CRYPTO_KEY_HASH     = "sha256"
    CRYPTO_KEY_SIZE     = "256"
    CRYPTO_PBKDF        = "argon2i"
  }
}

# Credentials for the S3 backup target (bucket/region/path are in gitops/longhorn/values.yaml).
# Key names are what Longhorn expects for an s3:// backupTarget.
resource "kubernetes_secret_v1" "longhorn_backup_s3" {
  metadata {
    name      = "longhorn-backup-s3"
    namespace = kubernetes_namespace_v1.longhorn.metadata[0].name
  }
  data = {
    AWS_ACCESS_KEY_ID     = var.longhorn_s3_access_key
    AWS_SECRET_ACCESS_KEY = var.longhorn_s3_secret_key
    AWS_ENDPOINTS         = var.longhorn_s3_endpoint
  }

  lifecycle {
    ignore_changes = [metadata[0].annotations] # Longhorn stamps longhorn.io/backup-target on it; don't fight over it
  }
}
