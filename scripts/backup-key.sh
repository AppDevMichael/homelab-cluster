#!/usr/bin/env bash
# Derives the cluster backup/encryption passphrase from a key in your SSH agent.
#
# How: `ssh-keygen -Y sign` asks the agent to sign a fixed message. Ed25519 (and RSA) signatures
# are DETERMINISTIC, so the same key + same message always yields the same bytes. We hash that.
# The private key never leaves the agent (works with 1Password, Secretive, gpg-agent, plain ssh-agent).
#
#   export BACKUP_KEY=$(scripts/backup-key.sh)
#
# ⚠  Print it once and store it in your password manager too: if you lose this SSH key,
#    every backup is unrecoverable. Do NOT use ECDSA or FIDO/sk keys — their signatures are randomised.
set -euo pipefail

PUBKEY="${BACKUP_SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub}"
NAMESPACE="opi-k8s-backup"       # changing this or the message changes the derived key
MESSAGE="opi-k8s cluster backup key v1"

[[ -r "$PUBKEY" ]] || { echo "public key not found: $PUBKEY (set BACKUP_SSH_PUBKEY)" >&2; exit 1; }
grep -qE '^(ssh-ed25519|ssh-rsa) ' "$PUBKEY" || { echo "need an ed25519 or rsa key (deterministic signatures)" >&2; exit 1; }

sig=$(printf '%s' "$MESSAGE" | ssh-keygen -Y sign -n "$NAMESPACE" -f "$PUBKEY" 2>/dev/null) \
  || { echo "signing failed — is the key loaded in your agent? (ssh-add -L)" >&2; exit 1; }

printf '%s' "$sig" | sed '/^-----/d' | tr -d '\n' | sha256sum | cut -c1-64
