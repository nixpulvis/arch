#!/bin/bash
set -e

usage() {
    echo $verbose
    echo "TODO"
    exit $1
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
    if ending_digit $1; then
        echo "$1p$2"
    else
        echo "$1$2"
    fi
}

# Parse the command line arguments.
while getopts 've:h' arg; do case "${arg}" in
        v) verbose=true ;;
        e) erase="${OPTARG}" ;;
        h) usage 0 ;;
        *)
           echo "Invalid argument '${arg}'"
           usage 1
           ;;
    esac
done
shift $((OPTIND -1))
target=$1
boot=$(partition_name $target 1)
root=$(partition_name $target 2)

confirm() {
    read -p "Are you sure? [Y/n] " answer
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
    echo "Bootstrapping $target, this will format the device."
    if [ -n "$erase" ]; then
        echo "Erasing $target with $erase, this can take a while."
    fi

    lsblk $target
    confirm
    echo

    # From this point on we don't ask the user for anything.

    # Remove all mounts of the target device.
    if umount $target?* 2>| grep -q 'target is busy'; then
        error "could not unmount $target"
    fi

    # TODO: Mount a plain crypt and wipe with that.
    if [ -n "$erase" ]; then
        dd if=$erase of=$target status=progress
    fi

    # Try to get the OS to ignore the old partitions.
    partx -u $target

    # Format the target with a GPT, 512MB EFI partition #1 and the rest
    # for the root filesystem.
    fdisk $target << EOF
g
n


+512M
t
1
n



p
w
EOF
    cryptsetup luksFormat $root
    cryptsetup luksOpen $root cryptroot

    # Setup the filesystems.
    mkfs.vfat -F32 $boot
    mkfs.ext4 /dev/mapper/cryptroot
}

# Installs an updated Arch to the formatted target
install() {
    mkdir -p mnt
    mount /dev/mapper/cryptroot mnt
    mkdir -p mnt/boot
    mount $boot mnt/boot

    # TODO: Check for network.
    # TODO: Check host locale settings.

    # Install Arch (requires network connection).
    cat packages.txt | xargs pacstrap mnt

    # Configure fstab for the new install to correctly mount filesystems on boot.
    genfstab -U mnt >> mnt/etc/fstab

    cp rootfs/etc/mkinitcpio.conf mnt/etc/mkinitcpio.conf

    arch-chroot mnt << EOF
mkinitcpio -p linux
bootctl --no-variables --path=/boot install
chsh -s /usr/bin/fish
passwd -d root
EOF

    # Configure the bootloader entry.
    mkdir -p mnt/boot/loader/entries
    cp rootfs/boot/loader/loader.conf mnt/boot/loader/loader.conf
    partuuid=`find -L /dev/disk/by-partuuid -samefile $root | xargs basename`
    sed -e "s/XXXX/${partuuid}/" rootfs/boot/loader/entries/arch.conf > mnt/boot/loader/entries/arch.conf

    # Set the DNS server.
    cp rootfs/etc/resolv.conf mnt/etc/resolv.conf

    umount mnt/boot
    umount mnt
    rm -r mnt
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
