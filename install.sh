#!/bin/bash
#
# Install Arch Linux onto a pre-formatted root with an existing ESP.
#
# Pacstraps a base system into the opened LUKS root, generates a
# Unified Kernel Image at $ESP/EFI/Linux/<name>.efi, and installs (or
# updates) systemd-boot on the ESP. Microcode is selected from
# /proc/cpuinfo so only the matching intel-ucode or amd-ucode package
# lands on disk.
#
# Run format.sh first to partition the disk, format the ESP, and open
# the LUKS root. Two install.sh runs against the same -b ESP with
# distinct -n names produce a dual-boot setup.
#
# Requires: arch-install-scripts (pacstrap, genfstab, arch-chroot),
# cryptsetup, util-linux. Run as root.
#
# See also: format.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "Usage: install.sh -b <esp> [-n <name>] <root-mapper>"
    echo
    echo "Install Arch Linux onto a pre-formatted root with an existing ESP."
    echo
    echo "  -b <esp>     ESP partition (e.g. /dev/vda1). Mounted at /efi."
    echo "  -n <name>    Name for this install (default: arch). Used as"
    echo "               \$ESP/EFI/Linux/<name>.efi for the UKI, and as"
    echo "               'Arch Linux (<name>)' for the systemd-boot menu entry."
    echo "  -h           Show this help."
    echo
    echo "<root-mapper> is the opened LUKS mapper (e.g. /dev/mapper/cryptroot-2)."
    echo "Run format.sh first to partition the disk and open the LUKS root."
    exit "${1:-0}"
}

error() { echo "ERROR: $1"; exit 1; }

# Pick the microcode package matching the host CPU. Empty for VMs/exotic.
ucode_package() {
    case "$(awk -F: '/vendor_id/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)" in
        GenuineIntel) echo intel-ucode ;;
        AuthenticAMD) echo amd-ucode ;;
    esac
}

name="arch"
boot=

while getopts 'b:n:h' arg; do case "${arg}" in
    b) boot="${OPTARG}" ;;
    n) name="${OPTARG}" ;;
    h) usage 0 ;;
    *) usage 1 ;;
esac done
shift $((OPTIND - 1))
root=$1

[[ $EUID -ne 0 ]] && error "run this script as root."
[ -z "$boot" ] && usage 1
[ -z "$root" ] && usage 1
[ -b "$root" ] || error "$root is not a block device."
[ -b "$boot" ] || error "$boot is not a block device."

# blkid on the mapper returns the inner ext4 UUID; we need the LUKS
# header UUID, which lives on the underlying partition.
root_part=$(cryptsetup status "$root" | awk '/^[[:space:]]*device:/ {print $2}')
[ -z "$root_part" ] && error "$root is not an open LUKS mapping."

install() {
    MNT=$(mktemp -d)
    mount "$root" "$MNT"
    mkdir -p "$MNT/efi"
    mount "$boot" "$MNT/efi"

    # Seed vconsole.conf before pacstrap so the linux package's post-install
    # hook (which runs mkinitcpio with the keymap hook) doesn't error.
    mkdir -p "$MNT/etc"
    cp "$SCRIPT_DIR/rootfs/etc/vconsole.conf" "$MNT/etc/vconsole.conf"

    # Build the package list with the matching microcode appended.
    ucode=$(ucode_package)
    PACSTRAP_PACKAGES=$(mktemp)
    cp "$SCRIPT_DIR/packages.txt" "$PACSTRAP_PACKAGES"
    if [ -n "$ucode" ]; then
        echo "$ucode" >> "$PACSTRAP_PACKAGES"
    fi

    # If an offline repo exists (built into the ISO), add it as a fallback
    # so pacstrap can work offline. Remote packages are preferred when
    # the network is available.
    OFFLINE_REPO="$SCRIPT_DIR/offline-repo"
    if curl -s --head --max-time 5 https://archlinux.org > /dev/null 2>&1; then
        echo "Network available, installing from remote repos."
        xargs pacstrap "$MNT" < "$PACSTRAP_PACKAGES"
    elif [ -d "$OFFLINE_REPO" ]; then
        echo "No network, installing from offline repo."
        PACMAN_CONF=$(mktemp)
        cat > "$PACMAN_CONF" << CONF
[options]
HoldPkg = pacman glibc
Architecture = auto

[offline]
SigLevel = Optional TrustAll
Server = file://$OFFLINE_REPO
CONF
        xargs pacstrap -C "$PACMAN_CONF" "$MNT" < "$PACSTRAP_PACKAGES"
        rm "$PACMAN_CONF"
    else
        error "no network and no offline repo available."
    fi
    rm "$PACSTRAP_PACKAGES"

    # Configure fstab for the new install to correctly mount filesystems on boot.
    genfstab -U "$MNT" >> "$MNT/etc/fstab"

    # Stage initramfs / UKI inputs before mkinitcpio runs.
    cp "$SCRIPT_DIR/rootfs/etc/mkinitcpio.conf" "$MNT/etc/mkinitcpio.conf"
    luks_uuid=$(cryptsetup luksUUID "$root_part")
    if [ -z "$luks_uuid" ]; then
        error "no LUKS UUID for $root_part. Aborting before generating a UKI with a broken kernel cmdline."
    fi
    sed -e "s/XXXX/${luks_uuid}/" \
        "$SCRIPT_DIR/rootfs/etc/kernel/cmdline" > "$MNT/etc/kernel/cmdline"
    sed -e "s/UKINAME/${name}/g" \
        "$SCRIPT_DIR/rootfs/etc/mkinitcpio.d/linux.preset" \
        > "$MNT/etc/mkinitcpio.d/linux.preset"

    # mkinitcpio bakes /etc/os-release into the UKI's .osrel section,
    # which systemd-boot uses for the menu title. Customizing PRETTY_NAME
    # here gives this install a distinct entry rather than another
    # generic "Arch Linux".
    sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Arch Linux (${name})\"/" \
        "$MNT/etc/os-release"

    # mkinitcpio -U needs the UKI's parent dir to exist beforehand.
    mkdir -p "$MNT/efi/EFI/Linux"

    # On a fresh ESP, install systemd-boot. On a shared ESP, only update
    # an already-installed copy (and leave it alone if newer than ours).
    if [ -f "$MNT/efi/EFI/systemd/systemd-bootx64.efi" ]; then
        bootctl_action="update"
    else
        bootctl_action="install"
    fi

    arch-chroot "$MNT" << EOF
set -e
mkinitcpio -P
bootctl --esp-path=/efi $bootctl_action
systemctl enable dhcpcd
chsh -s /usr/bin/fish
passwd -d root
EOF

    # Write loader.conf whenever we freshly installed systemd-boot.
    # bootctl install's default has no `timeout`, which means auto-boot
    # the first entry with no menu. That breaks discoverability for
    # both single-OS installs (no recovery path) and dual-boot. If
    # systemd-boot was already there ($bootctl_action = update), the
    # existing config was set by whoever installed first; leave it.
    if [ "$bootctl_action" = "install" ]; then
        sed -e "s/UKINAME/${name}/g" \
            "$SCRIPT_DIR/rootfs/boot/loader/loader.conf" \
            > "$MNT/efi/loader/loader.conf"
    fi

    # Set the DNS server.
    cp "$SCRIPT_DIR/rootfs/etc/resolv.conf" "$MNT/etc/resolv.conf"

    echo "Syncing to disk..."
    while grep -q '^Dirty:\s*[1-9]' /proc/meminfo; do
        dirty=$(awk '/^Dirty:/ {print $2, $3}' /proc/meminfo)
        printf "\r  %s remaining..." "$dirty"
        sleep 1
    done
    printf "\r  done.%20s\n" ""

    umount "$MNT/efi"
    umount "$MNT"
    rmdir "$MNT"
}

install
