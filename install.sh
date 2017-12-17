#!/bin/bash

set -e

usage() {
    echo "TODO"
    exit $1
}

confirm() {
    read -p "Are you sure? [Y/n] " answer
    case "$answer" in
        [yY][eE][sS]|[yY])
	    ;;
	*)
	    echo "Quitting..."
	    exit 0
	    ;;
    esac
}

while getopts 'e:h' arg; do
    case "${arg}" in
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

if [ -z "$target" ]; then
    usage 1
fi

# Confirm the target.
echo "Bootstrapping $target, this will format the device."

# Warn users about erase time.
if [ -n "$erase" ]; then
    echo "Erasing $target with $erase, this can take a while."
fi

# Display some information about the target device.
lsblk $target 

confirm
# From this point on we don't ask the user for anything.

if [ -n "$erase" ]; then
    dd if=$erase of=$target status=progress
fi

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

# Setup the filesystems.
mkfs.vfat -F32 ${target}1
mkfs.ext4 -F ${target}2

# TODO: One day we'll encrypt, maybe.

# Create a local mountpoints.
mkdir -p mnt
mount ${target}2 mnt
mkdir -p mnt/boot
mount ${target}1 mnt/boot

# Install systemd-boot to the ESP.
bootctl --no-variables --path=mnt/boot install

# Configure the bootloader entry.
cp loader.conf mnt/boot/loader/loader.conf
partuuid=`find -L /dev/disk/by-partuuid -samefile ${target}2 | xargs basename`
sed -e "s/XXXX/${partuuid}/" arch.conf > mnt/boot/loader/entries/arch.conf

exit 1

# Install Arch (requires network connection).
# TODO: Here is as good a place as any to install all the packages.
# - `intel-ucode`
# - `fish`
# - ...
pacstrap mnt base

# Configure fstab for the new install to correctly mount filesystems on boot.
genfstab -U mnt >> mnt/etc/fstab

# chroot into the new installation.
arch-chroot mnt

# TODO: NTP Date/time
# TODO: HW clock
# TODO: Locale
# TODO: Password
# TODO: Hostname
# TODO: Root shell -> fish
# TODO: Create nixpulvis user (fish shell)
# TODO: Install dotfiles

# Leave the chroot environmnt.
exit

# Clean up the local mountpoints.
umount mnt/boot
umount mnt
rm -r mnt

