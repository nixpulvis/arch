#!/bin/bash

set -e

# Parse the command line arguments.
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

bootstrap() {
    # Confirm the target.
    echo "Bootstrapping $target, this will format the device."
    
    # Warn users about erase time.
    if [ -n "$erase" ]; then
        echo "Erasing $target with $erase, this can take a while."
    fi
    
    # Display some information about the target device.
    lsblk $target 
    
    confirm
    echo

    # From this point on we don't ask the user for anything.
    
    # Remove all mounts of the target device.
    umount $target?* 2>/dev/null || true

    if [ -n "$erase" ]; then
        dd if=$erase of=$target status=progress
    fi

    echo $target

    # Format the device. 
    # NOTE: Try to get the OS to ignore the old partitions.
    partx -u $target
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
}

install() {
    mkdir -p mnt
    mount ${target}2 mnt
    mkdir -p mnt/boot
    mount ${target}1 mnt/boot

    # TODO: Check for network.
    # TODO: Check host locale settings.

    # Install Arch (requires network connection).
    cat packages.txt | xargs pacstrap mnt
    
    # Configure fstab for the new install to correctly mount filesystems on boot.
    genfstab -U mnt >> mnt/etc/fstab

    # Configure the bootloader entry.
    mkdir -p mnt/loader/entries
    cp rootfs/boot/loader/loader.conf mnt/loader/loader.conf
    partuuid=`find -L /dev/disk/by-partuuid -samefile ${target}2 | xargs basename`
    sed -e "s/XXXX/${partuuid}/" rootfs/boot/loader/entries/arch.conf > mnt/loader/entries/arch.conf

    umount mnt/boot
    umount mnt
    rm -r mnt
}

configure() {
    mkdir -p mnt
    mount ${target}2 mnt
    mkdir -p mnt/boot
    mount ${target}1 mnt/boot

    arch-chroot mnt << EOF
bootctl --no-variables --path=/boot install
EOF

    umount mnt/boot

    cp -rp rootfs/* mnt
    ln -sf mnt/usr/lib/systemd/system/install.service mnt/etc/systemd/system/getty.target.wants/install.service
    
    # FIXME: Seems to run, but doesn't exit correctly. Leaves a running systemd-nspawn process.
    sleep 1
    systemd-nspawn -bD mnt

    umount mnt
    rm -r mnt
}

# Check the arguments.
if [ -z "$target" ]; then
    usage 1
fi

# Do the work!
bootstrap
install
configure

