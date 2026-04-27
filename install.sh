#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "Usage: install.sh [-e <source>] [-b <esp>] [-n <name>] <device>"
    echo
    echo "Install Arch Linux to a target device with LUKS encryption."
    echo
    echo "  -e <source>  Erase the device first (e.g. -e /dev/urandom)"
    echo "  -b <esp>     Reuse an existing ESP partition (dual-boot). <device>"
    echo "               is treated as the root partition; no GPT changes are"
    echo "               made and the existing loader config is preserved."
    echo "  -n <name>    Name for this install (default: arch). Used as"
    echo "               \$ESP/EFI/Linux/<name>.efi for the UKI, and as"
    echo "               'Arch Linux (<name>)' for the systemd-boot menu entry."
    echo "  -h           Show this help"
    exit "$1"
}

error() {
    echo "ERROR: $1"
    exit 1
}

ending_digit() {
    case $1 in
        *[0-9]) true ;;
        *) false ;;
    esac
}

partition_name() {
    if ending_digit "$1"; then
        echo "$1p$2"
    else
        echo "$1$2"
    fi
}

# Pick the microcode package matching the host CPU. Empty for VMs/exotic.
ucode_package() {
    case "$(awk -F: '/vendor_id/ {gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)" in
        GenuineIntel) echo intel-ucode ;;
        AuthenticAMD) echo amd-ucode ;;
    esac
}

name="arch"

# Parse the command line arguments.
while getopts 'e:b:n:h' arg; do case "${arg}" in
        e) erase="${OPTARG}" ;;
        b) dual_boot_esp="${OPTARG}" ;;
        n) name="${OPTARG}" ;;
        h) usage 0 ;;
        *)
           echo "Invalid argument '${arg}'"
           usage 1
           ;;
    esac
done
shift $((OPTIND -1))
target=$1

if [ -n "$dual_boot_esp" ]; then
    # Dual-boot mode: caller supplies a pre-partitioned root device and
    # an existing ESP. We don't touch the GPT.
    boot=$dual_boot_esp
    root=$target
else
    boot=$(partition_name "$target" 1)
    root=$(partition_name "$target" 2)
fi

confirm() {
    read -rp "Are you sure? [Y/n] " answer
    case "$answer" in
        [yY][eE][sS]|[yY])
	    ;;
	*)
	    echo "quitting."
	    exit 0
	    ;;
    esac
}

# Format, partitions and creates the file systems for a new installation.
# This function can optionally wipe the old data by simply writing over it
# all.
bootstrap() {
    if [ -n "$dual_boot_esp" ]; then
        echo "Bootstrapping $target as the root partition; reusing ESP $boot."
    else
        echo "Bootstrapping $target, this will format the device."
    fi
    if [ -n "$erase" ]; then
        echo "Erasing $target with $erase, this can take a while."
    fi

    lsblk "$target"
    confirm
    echo

    # From this point on we don't ask the user for anything.

    # Remove all mounts of the target device.
    if umount "$target"?* 2>&1 | grep -q 'target is busy'; then
        error "could not unmount $target"
    fi

    # TODO: Mount a plain crypt and wipe with that.
    # When the drive's firmware is trusted, prefer hardware secure-erase
    # over a software wipe: `blkdiscard $target` for SATA SSDs (TRIM),
    # `nvme format --ses=1 $target` for NVMe, or `hdparm --security-erase`
    # for ATA drives that support it.
    if [ -n "$erase" ]; then
        dd if="$erase" of="$target" status=progress
    fi

    # Clear old partition signatures so fdisk starts clean.
    wipefs -a "$target"

    if [ -z "$dual_boot_esp" ]; then
        # Format the target with a GPT, 512MB EFI partition #1 and the rest
        # for the root filesystem.
        fdisk "$target" << EOF
g
n


+512M
t
1
n



p
w
EOF
        # Force the kernel to re-read the partition table and wait for udev
        # to create the new partition device nodes before we format them.
        partprobe "$target"
        udevadm settle
        mkfs.vfat -F32 "$boot"
    fi

    cryptsetup luksFormat "$root"
    cryptsetup luksOpen "$root" cryptroot
    mkfs.ext4 /dev/mapper/cryptroot
}

# Installs an updated Arch to the formatted target
install() {
    MNT=$(mktemp -d)
    mount /dev/mapper/cryptroot "$MNT"
    mkdir -p "$MNT/efi"
    mount "$boot" "$MNT/efi"

    # Seed vconsole.conf before pacstrap so the linux package's post-install
    # hook (which runs mkinitcpio with the keymap hook) doesn't error.
    mkdir -p "$MNT/etc"
    cp "$SCRIPT_DIR/rootfs/etc/vconsole.conf" "$MNT/etc/vconsole.conf"

    # TODO: Check host locale settings.

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
    # LUKS header UUID rather than partition PARTUUID: works for both
    # partition-LUKS and whole-disk-LUKS targets; cryptsetup stamps it
    # at format time so it's always available now.
    luks_uuid=$(blkid -s UUID -o value "$root")
    if [ -z "$luks_uuid" ]; then
        error "blkid found no UUID on $root after LUKS format. Aborting before generating a UKI with a broken kernel cmdline."
    fi
    sed -e "s/XXXX/${luks_uuid}/" \
        "$SCRIPT_DIR/rootfs/etc/kernel/cmdline" > "$MNT/etc/kernel/cmdline"
    sed -e "s/UKINAME/${name}/g" \
        "$SCRIPT_DIR/rootfs/etc/mkinitcpio.d/linux.preset" \
        > "$MNT/etc/mkinitcpio.d/linux.preset"

    # Per-install os-release for the UKI's .osrel section so this
    # install's entry is identifiable in systemd-boot's menu rather
    # than blending in with every other "Arch Linux" UKI on the ESP.
    sed -e "s/^PRETTY_NAME=.*/PRETTY_NAME=\"Arch Linux (${name})\"/" \
        "$MNT/etc/os-release" > "$MNT/etc/uki-os-release"

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

    # Write loader.conf whenever we freshly installed systemd-boot —
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


# Check for root user.
if [[ $EUID -ne 0 ]]; then
    error "run this script as root."
fi

# Check the arguments.
if [ -z "$target" ]; then
    usage 1
fi

bootstrap
install
