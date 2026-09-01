#!/usr/bin/env bash
# OPTIONAL. Pre-seeds a freshly flashed Armbian SD card with your SSH key so the very first Ansible
# connection is key-based instead of the default root/1234 password. Needs Linux (ext4).
#   sudo scripts/prepare-sd.sh /dev/sdX ~/.ssh/id_ed25519.pub
set -euo pipefail
DEV="${1:?block device of the SD card}"; PUB="${2:-$HOME/.ssh/id_ed25519.pub}"
PART=$(lsblk -nrpo NAME,FSTYPE "$DEV" | awk '$2=="ext4"{print $1; exit}')
[[ -n "$PART" ]] || { echo "no ext4 partition found on $DEV"; exit 1; }
M=$(mktemp -d); mount "$PART" "$M"; trap 'umount "$M"; rmdir "$M"' EXIT
install -d -m700 "$M/root/.ssh"; cat "$PUB" >> "$M/root/.ssh/authorized_keys"; chmod 600 "$M/root/.ssh/authorized_keys"
rm -f "$M/root/.not_logged_in_yet"          # no first-login wizard
echo "seeded $PART with $(cut -d' ' -f3 "$PUB")"
