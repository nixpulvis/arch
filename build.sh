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
#   - packages.txt packages are cached into a offline repo for offline installs
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
WORK=$(mktemp -d --tmpdir="$SCRIPT_DIR")
OUT="${SCRIPT_DIR}/out"
trap "rm -rf $WORK" EXIT

echo "Building ISO in $WORK ..."

# Copy the releng profile as our base.
cp -r "$RELENG"/* "$WORK"/

# Merge our packages into the live image's package list.
#    Filter comments and blank lines from packages.txt, append any
#    that aren't already present.
while IFS= read -r pkg; do
    [[ -z "$pkg" || "$pkg" = \#* ]] && continue
    if ! grep -qx "$pkg" "$WORK/packages.x86_64"; then
        echo "$pkg" >> "$WORK/packages.x86_64"
    fi
done < "$SCRIPT_DIR/packages.txt"

# Build AUR packages and create a local repo.
AUR_PACKAGES=(downgrade paru-bin)
AUR_REPO="$WORK/aur-repo"
mkdir -p "$AUR_REPO"

BUILDDIR=$(sudo -u "$SUDO_USER" mktemp -d)
for pkg in "${AUR_PACKAGES[@]}"; do
    echo "Building AUR package: $pkg"
    cd "$BUILDDIR"
    sudo -u "$SUDO_USER" git clone "https://aur.archlinux.org/$pkg.git"
    cd "$pkg"
    sudo -u "$SUDO_USER" makepkg -s --noconfirm
    cp *.pkg.tar.zst "$AUR_REPO/"
    echo "$pkg" >> "$WORK/packages.x86_64"
done
rm -rf "$BUILDDIR"
cd "$SCRIPT_DIR"

# Create the repo database.
repo-add "$AUR_REPO/custom.db.tar.gz" "$AUR_REPO"/*.pkg.tar.zst

# Add the AUR repo to pacman.conf.
cat >> "$WORK/pacman.conf" << EOF

[custom]
SigLevel = Optional TrustAll
Server = file://$AUR_REPO
EOF

# Download packages.txt packages into a offline repo for offline installs.
OFFLINE_REPO="$WORK/airootfs/root/offline-repo"
DOWNLOAD_CACHE=$(mktemp -d)
chmod 777 "$DOWNLOAD_CACHE"
FAKE_DB=$(mktemp -d)
chmod 777 "$FAKE_DB"
mkdir -p "$FAKE_DB/local"
cat "$SCRIPT_DIR/packages.txt" | xargs pacman -Syw --noconfirm --cachedir "$DOWNLOAD_CACHE" --dbpath "$FAKE_DB"
rm -rf "$FAKE_DB"
mkdir -p "$OFFLINE_REPO"
mv "$DOWNLOAD_CACHE"/*.pkg.tar.zst "$OFFLINE_REPO/"
rm -rf "$DOWNLOAD_CACHE"
cp "$AUR_REPO"/*.pkg.tar.zst "$OFFLINE_REPO/"
repo-add "$OFFLINE_REPO/offline.db.tar.gz" "$OFFLINE_REPO"/*.pkg.tar.zst

# Copy the installer into /root on the live filesystem.
cp "$SCRIPT_DIR/install.sh" "$WORK/airootfs/root/"
cp "$SCRIPT_DIR/packages.txt" "$WORK/airootfs/root/"
cp -r "$SCRIPT_DIR/rootfs" "$WORK/airootfs/root/"

# Patch profiledef.sh with our ISO metadata.
sed -i 's/^iso_name=.*/iso_name="archlinux-nixpulvis"/' "$WORK/profiledef.sh"
sed -i 's/^iso_publisher=.*/iso_publisher="nixpulvis"/' "$WORK/profiledef.sh"
sed -i 's/^iso_application=.*/iso_application="Arch Linux Live\/Install"/' "$WORK/profiledef.sh"
sed -i "s/airootfs_image_tool_options=.*/airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15')/" "$WORK/profiledef.sh"

# Set the default shell to fish on the live image.
sed -i 's|root:/usr/bin/zsh|root:/usr/bin/fish|' "$WORK/airootfs/etc/passwd"

# Set the MOTD (overwrite releng's motd in the profile's airootfs).
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
