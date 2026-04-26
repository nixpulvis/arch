#!/bin/bash
#
# Build a bootable Arch Linux ISO with the installer baked in.
#
# Requires: archiso
#
# The ISO is built from the stock releng profile with the following
# modifications applied at build time:
#
#   - packages.x86_64 is merged with our packages.txt
#   - AUR packages (downgrade, paru-bin) are built and added as a local repo
#   - install.sh, packages.txt, and rootfs/ are copied into /root
#   - profiledef.sh is patched with our ISO metadata
#   - The default shell is set to fish
#   - MOTD is set with version and build date
#   - SHA256 checksum is generated for the output ISO
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELENG="/usr/share/archiso/configs/releng"

if [ ! -d "$RELENG" ]; then
    echo "ERROR: archiso releng profile not found at $RELENG"
    echo "Install archiso: pacman -S archiso"
    exit 1
fi

# Check for root.
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run this script as root."
    exit 1
fi

# Setup a temp dir for the build profile. Cleaned up on exit.
WORK=$(mktemp -d)
OUT="${SCRIPT_DIR}/out"
trap "rm -rf $WORK" EXIT

echo "Building ISO in $WORK ..."

# 1. Copy the releng profile as our base.
cp -r "$RELENG"/* "$WORK"/

# 2. Merge our packages into the live image's package list.
#    Filter comments and blank lines from packages.txt, append any
#    that aren't already present.
while IFS= read -r pkg; do
    [[ -z "$pkg" || "$pkg" = \#* ]] && continue
    if ! grep -qx "$pkg" "$WORK/packages.x86_64"; then
        echo "$pkg" >> "$WORK/packages.x86_64"
    fi
done < "$SCRIPT_DIR/packages.txt"

# 3. Build AUR packages and create a local repo.
AUR_PACKAGES=(downgrade paru-bin)
LOCAL_REPO="$WORK/local-repo"
mkdir -p "$LOCAL_REPO"

BUILDDIR=$(sudo -u "$SUDO_USER" mktemp -d)
for pkg in "${AUR_PACKAGES[@]}"; do
    echo "Building AUR package: $pkg"
    cd "$BUILDDIR"
    sudo -u "$SUDO_USER" git clone "https://aur.archlinux.org/$pkg.git"
    cd "$pkg"
    sudo -u "$SUDO_USER" makepkg -s --noconfirm
    cp *.pkg.tar.zst "$LOCAL_REPO/"
    echo "$pkg" >> "$WORK/packages.x86_64"
done
rm -rf "$BUILDDIR"
cd "$SCRIPT_DIR"

# Create the repo database.
repo-add "$LOCAL_REPO/custom.db.tar.gz" "$LOCAL_REPO"/*.pkg.tar.zst

# Add the local repo to pacman.conf.
cat >> "$WORK/pacman.conf" << EOF

[custom]
SigLevel = Optional TrustAll
Server = file://$LOCAL_REPO
EOF

# 4. Copy the installer into /root on the live filesystem.
cp "$SCRIPT_DIR/install.sh" "$WORK/airootfs/root/"
cp "$SCRIPT_DIR/packages.txt" "$WORK/airootfs/root/"
cp -r "$SCRIPT_DIR/rootfs" "$WORK/airootfs/root/"

# 5. Patch profiledef.sh with our ISO metadata.
sed -i 's/^iso_name=.*/iso_name="archlinux-nixpulvis"/' "$WORK/profiledef.sh"
sed -i 's/^iso_publisher=.*/iso_publisher="nixpulvis"/' "$WORK/profiledef.sh"
sed -i 's/^iso_application=.*/iso_application="Arch Linux Live\/Install"/' "$WORK/profiledef.sh"

# 6. Set the default shell to fish on the live image.
sed -i 's|root:/usr/bin/zsh|root:/usr/bin/fish|' "$WORK/airootfs/etc/passwd"

# 7. Set the MOTD.
ARCH_VERSION=$(pacman -Q linux | awk '{print $2}')
BUILD_DATE=$(date +%Y-%m-%d)
cat > "$WORK/airootfs/etc/motd" << EOF

  nixpulvis
  Arch Linux Installer
  $ARCH_VERSION
  $BUILD_DATE

  Install to a device:
    ./install.sh /dev/sdX

EOF

# Build the ISO.
mkdir -p "$OUT"
mkarchiso -v -w "$WORK/work" -o "$OUT" "$WORK"

# Generate checksum.
sha256sum "$OUT"/archlinux-nixpulvis-*.iso > "$OUT/sha256sum.txt"

echo
echo "ISO written to $OUT/"
ls -lh "$OUT"/*.iso
cat "$OUT/sha256sum.txt"
