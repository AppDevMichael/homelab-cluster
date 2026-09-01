# Longhorn namespace + the two secrets it needs. Longhorn itself is deployed by ArgoCD (gitops/longhorn).

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

# Credentials for the SMB backup target on the Storage Box.
resource "kubernetes_secret_v1" "longhorn_backup_cifs" {
  metadata {
    name      = "longhorn-backup-cifs"
    namespace = kubernetes_namespace_v1.longhorn.metadata[0].name
  }
  data = {
    CIFS_USERNAME = var.storagebox_user
    CIFS_PASSWORD = var.storagebox_password
  }
}
