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

# Parse options.
while getopts 'so:h' arg; do case "${arg}" in
        s) enable_sshd=true ;;
        o) offline_repo_path="${OPTARG}" ;;
        h) echo "Usage: build.sh [-s] [-o <path>]"
           echo
           echo "Build a bootable Arch Linux ISO with the installer baked in."
           echo
           echo "  -s         Enable sshd on the live image"
           echo "  -o <path>  Path to existing offline repo (default: \$SCRIPT_DIR/offline-repo)"
           echo "  -h         Show this help"
           exit 0 ;;
    esac
done
offline_repo_path="${offline_repo_path:-$SCRIPT_DIR/offline-repo}"

# Check for root.
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run this script as root."
    exit 1
fi

# Setup a temp dir for the build profile. Cleaned up on exit.
WORK=$(mktemp -d --tmpdir="$SCRIPT_DIR")
OUT="${SCRIPT_DIR}/out"
CLEANUP_USER=""
cleanup() {
    [ -n "$CLEANUP_USER" ] && userdel -r "$CLEANUP_USER"
    rm -rf "$WORK"
}
trap cleanup EXIT

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

# Build AUR packages and populate the offline repo.
AUR_PACKAGES=(downgrade paru-bin)
AUR_REPO="$WORK/aur-repo"
OFFLINE_REPO="$WORK/airootfs/root/offline-repo"
mkdir -p "$AUR_REPO" "$OFFLINE_REPO"

if curl -s --head --max-time 5 https://aur.archlinux.org > /dev/null 2>&1; then
    # makepkg refuses to run as root, so we need a non-root user.
    BUILD_USER="${SUDO_USER:-}"
    if [ -z "$BUILD_USER" ]; then
        BUILD_USER="builduser"
        useradd -m "$BUILD_USER"
        CLEANUP_USER="$BUILD_USER"
    fi

    BUILDDIR=$(sudo -u "$BUILD_USER" mktemp -d)
    for pkg in "${AUR_PACKAGES[@]}"; do
        echo "Building AUR package: $pkg"
        cd "$BUILDDIR"
        sudo -u "$BUILD_USER" git clone "https://aur.archlinux.org/$pkg.git"
        cd "$pkg"
        sudo -u "$BUILD_USER" makepkg -s --noconfirm
        cp *.pkg.tar.zst "$AUR_REPO/"
        echo "$pkg" >> "$WORK/packages.x86_64"
    done
    rm -rf "$BUILDDIR"
    cd "$SCRIPT_DIR"

    # Download packages.txt packages into the offline repo.
    DOWNLOAD_CACHE=$(mktemp -d)
    chmod 777 "$DOWNLOAD_CACHE"
    FAKE_DB=$(mktemp -d)
    chmod 777 "$FAKE_DB"
    mkdir -p "$FAKE_DB/local"
    cat "$SCRIPT_DIR/packages.txt" | xargs pacman -Syw --noconfirm --cachedir "$DOWNLOAD_CACHE" --dbpath "$FAKE_DB"
    rm -rf "$FAKE_DB"
    mv "$DOWNLOAD_CACHE"/*.pkg.tar.zst "$OFFLINE_REPO/"
    rm -rf "$DOWNLOAD_CACHE"
    cp "$AUR_REPO"/*.pkg.tar.zst "$OFFLINE_REPO/"
else
    echo "No network, copying existing offline repo."
    cp "$offline_repo_path"/*.pkg.tar.zst "$OFFLINE_REPO/"
    for pkg in "${AUR_PACKAGES[@]}"; do
        cp "$offline_repo_path"/$pkg-*.pkg.tar.zst "$AUR_REPO/"
        echo "$pkg" >> "$WORK/packages.x86_64"
    done
fi

# Create repo databases.
repo-add "$AUR_REPO/custom.db.tar.gz" "$AUR_REPO"/*.pkg.tar.zst
repo-add "$OFFLINE_REPO/offline.db.tar.gz" "$OFFLINE_REPO"/*.pkg.tar.zst

# Add the AUR repo to pacman.conf.
cat >> "$WORK/pacman.conf" << EOF

[custom]
SigLevel = Optional TrustAll
Server = file://$AUR_REPO
EOF

# Copy the installer and build script into /root on the live filesystem.
cp "$SCRIPT_DIR/install.sh" "$WORK/airootfs/root/"
cp "$SCRIPT_DIR/build.sh" "$WORK/airootfs/root/"
cp "$SCRIPT_DIR/packages.txt" "$WORK/airootfs/root/"
cp -r "$SCRIPT_DIR/rootfs" "$WORK/airootfs/root/"

# Patch profiledef.sh with our ISO metadata.
BUILD_DATE=$(date +%Y-%m-%dT%H:%M:%S)
sed -i 's/^iso_name=.*/iso_name="archlinux-nixpulvis"/' "$WORK/profiledef.sh"
sed -i "s/^iso_version=.*/iso_version=\"$BUILD_DATE\"/" "$WORK/profiledef.sh"
sed -i 's/^iso_publisher=.*/iso_publisher="nixpulvis"/' "$WORK/profiledef.sh"
sed -i 's/^iso_application=.*/iso_application="Arch Linux Live\/Install"/' "$WORK/profiledef.sh"
sed -i "s/airootfs_image_tool_options=.*/airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15')/" "$WORK/profiledef.sh"

# Register our scripts in archiso's file_permissions table.
sed -i 's|^file_permissions=(|file_permissions=(\n  ["/root/install.sh"]="0:0:755"\n  ["/root/build.sh"]="0:0:755"|' "$WORK/profiledef.sh"

# Set the default shell to bash on the live image (releng defaults to zsh).
sed -i 's|root:/usr/bin/zsh|root:/bin/bash|' "$WORK/airootfs/etc/passwd"

# Enable sshd on the live image if requested.
if [ "$enable_sshd" = true ]; then
    mkdir -p "$WORK/airootfs/etc/systemd/system/multi-user.target.wants"
    ln -s /usr/lib/systemd/system/sshd.service \
        "$WORK/airootfs/etc/systemd/system/multi-user.target.wants/sshd.service"
fi


# Set the MOTD (overwrite releng's motd in the profile's airootfs).
ARCH_VERSION=$(pacman -Q linux | awk '{print $2}')
cat > "$WORK/airootfs/etc/motd" << EOF

  nixpulvis
  Arch Linux (Live)
  $ARCH_VERSION
  $BUILD_DATE

  Install to a device:
    ./install.sh /dev/sdX

  Build a new ISO:
    ./build.sh
  To replicate this image as-is, dd directly from the boot media instead.

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
