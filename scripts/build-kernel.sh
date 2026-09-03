#!/usr/bin/env bash
# Build the custom Orange Pi 4 Pro vendor kernel with the Armbian build framework (inside Docker).
#
#   make kernel                      → kernel/debs/linux-{image,dtb,headers}-vendor-sun60iw2_*.deb
#   KERNEL_HEADLESS=0 make kernel    → keep HDMI/audio/Wi-Fi/BT drivers (only the storage extension)
#
# Pinned to the armbian/build commit the boards' images were built from (see /etc/armbian-release
# BUILD_REPOSITORY_COMMIT) so the kernel source, patches and u-boot expectations match exactly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KDIR="$REPO_ROOT/kernel"
BUILD_DIR="${ARMBIAN_BUILD_DIR:-$KDIR/build}"
ARMBIAN_COMMIT="${ARMBIAN_COMMIT:-8b778f3d82fb8dcfb3d663187de890a3700c8ee2}"   # = boards' BUILD_REPOSITORY_COMMIT
BOARD="orangepi4pro"
BRANCH="vendor"
KERNEL_HEADLESS="${KERNEL_HEADLESS:-1}"
KERNEL_DOCKER_DNS="${KERNEL_DOCKER_DNS:-1.1.1.1 8.8.8.8}"   # WSL2/Docker Desktop: host resolver is unreachable from containers; "" = keep Armbian default

command -v docker >/dev/null || { echo "docker is required (the build runs in a container)" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon not reachable" >&2; exit 1; }

# --- checkout armbian/build at the pinned commit -------------------------------------------------
if [[ ! -d "$BUILD_DIR/.git" ]]; then
  echo ">> cloning armbian/build @ ${ARMBIAN_COMMIT:0:9} into $BUILD_DIR"
  git init -q "$BUILD_DIR"
  git -C "$BUILD_DIR" remote add origin https://github.com/armbian/build.git
fi
if [[ "$(git -C "$BUILD_DIR" rev-parse HEAD 2>/dev/null || true)" != "$ARMBIAN_COMMIT" ]]; then
  git -C "$BUILD_DIR" fetch -q --depth 1 origin "$ARMBIAN_COMMIT"
  git -C "$BUILD_DIR" checkout -q --detach FETCH_HEAD
fi

# --- our extensions + version → userpatches/ (framework convention) ------------------------------
mkdir -p "$BUILD_DIR/userpatches/extensions"
cp "$KDIR/userpatches/VERSION" "$BUILD_DIR/userpatches/VERSION"
cp "$KDIR/userpatches/extensions/"*.sh "$BUILD_DIR/userpatches/extensions/"
EXTS="k8s-storage,docker-dns"
[[ "$KERNEL_HEADLESS" == "1" ]] && EXTS="$EXTS,headless-lowpower"

# --- build ----------------------------------------------------------------------------------------
echo ">> building kernel: BOARD=$BOARD BRANCH=$BRANCH EXT=$EXTS  (first run builds the docker image + downloads sources; expect 30–60 min)"
cd "$BUILD_DIR"
./compile.sh kernel \
  BOARD="$BOARD" BRANCH="$BRANCH" \
  ENABLE_EXTENSIONS="$EXTS" \
  PREFER_DOCKER=yes \
  KERNEL_DOCKER_DNS="$KERNEL_DOCKER_DNS" \
  KERNEL_CONFIGURE=no \
  SHARE_LOG=no

# --- collect ----------------------------------------------------------------------------------------
mkdir -p "$KDIR/debs"
rm -f "$KDIR/debs/"*.deb
found=0
while IFS= read -r deb; do
  cp -v "$deb" "$KDIR/debs/"; found=$((found+1))
done < <(find "$BUILD_DIR/output/debs" -name "linux-*-vendor-sun60iw2_*.deb" -newer "$KDIR/userpatches/VERSION" 2>/dev/null)
[[ $found -ge 2 ]] || { echo "expected linux-image + linux-dtb debs in $BUILD_DIR/output/debs — check $BUILD_DIR/output/logs" >&2; exit 1; }
# keep the effective .config next to the debs for review (extracted from the image package)
tmp=$(mktemp -d); dpkg-deb -x "$KDIR/debs/"linux-image-*.deb "$tmp"
cp "$tmp"/boot/config-* "$KDIR/debs/linux-sun60iw2-vendor.config"; rm -rf "$tmp"

echo ">> done:"; ls -la "$KDIR/debs/"
if [[ -f "$KDIR/debs/linux-sun60iw2-vendor.config" ]]; then
  echo ">> sanity (should all be =m or =y):"
  for opt in BLK_DEV_DM DM_CRYPT CRYPTO_XTS ISCSI_TCP; do
    grep -E "^CONFIG_${opt}=[my]" "$KDIR/debs/linux-sun60iw2-vendor.config" || { echo "!! CONFIG_${opt} missing — not shipping this kernel" >&2; rm -f "$KDIR/debs/"*.deb; exit 1; }
  done
fi
