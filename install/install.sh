#!/bin/bash

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
echo "Installing Arch Linux to $target."

# Setup the filesystems.
mkfs.vfat -F32 ${target}1
mkfs.ext4 -F ${target}2

# Create a local mountpoint.
mkdir -p mnt
mount ${target}2 mnt
mkdir -p mnt/boot
mount ${target}1 mnt/boot

pacstrap mnt base
genfstab -U mnt >> mnt/etc/fstab

# Clean up the local mountpoint.
umount mnt/boot
umount mnt
rm -r mnt

