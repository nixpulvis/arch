#!/bin/bash
#
# Dual-boot test: two Arch installs sharing one ESP. Partitions the
# disk inside the live ISO (no host nbd/sudo), then runs install.sh
# -b twice with different -n names so each install's UKI lands in
# /efi/EFI/Linux/ alongside the other.
#
# The result is left at ./test-disk.qcow2 (KEEP_DISK is forced) so
# you can chase up with test-boot.sh and inspect both UKIs:
#   ./test-install-dual.sh
#   sudo modprobe nbd max_part=8
#   sudo qemu-nbd --connect=/dev/nbd0 test-disk.qcow2
#   sudo mount /dev/nbd0p1 /mnt/test
#   ls /mnt/test/EFI/Linux/      # expect arch-a.efi + arch-b.efi
#                                # plus their -fallback.efi pair
#   sudo umount /mnt/test
#   sudo qemu-nbd --disconnect /dev/nbd0
#   sudo modprobe -r nbd
#   ./test-boot.sh               # boots whichever entry is default
#
# Requires: same as test-install-local.sh.
#
# Env: same as test-install-local.sh; DISK_SIZE defaults to 16G here
# (vs 8G elsewhere) to fit two installs.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Two 8G installs need a bigger disk than the single-install default.
# Set before sourcing so the lib's `${DISK_SIZE:-8G}` default doesn't win.
DISK_SIZE=${DISK_SIZE:-16G}

# shellcheck source=test-install-lib.sh
source "$SCRIPT_DIR/test-install-lib.sh"

# Force KEEP_DISK so test-boot.sh can pick up the result.
KEEP_DISK=1

check_deps

if [ $# -gt 0 ] && [ -f "$1" ]; then
    resolve_iso "$1"
    shift
else
    resolve_iso ""
fi

echo "ISO:      $ISO (live system only; installer comes from $SCRIPT_DIR)"
echo "Mode:     dual-boot (two installs sharing one ESP)"

prepare_qemu_inputs

echo "Disk:     $DISK ($DISK_SIZE)"
echo "Log:      $LOG"
echo

# Common preamble: mount the project tree from the host so install.sh
# and rootfs/ are available inside the VM.
QEMU_9P="-virtfs local,path=$SCRIPT_DIR,mount_tag=hostshare,security_model=none,readonly=on"
MOUNT_HOST="mkdir -p /mnt/host && mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/host && cd /mnt/host"

# Partition layout: 512 MiB ESP, then split the rest into two LUKS root
# slots (8 GiB each). The first install formats the ESP; the second
# install reuses it as-is.
PARTED='parted -s /dev/vda mklabel gpt mkpart ESP fat32 1MiB 513MiB set 1 esp on mkpart arch-a 513MiB 8GiB mkpart arch-b 8GiB 100% && partprobe /dev/vda && udevadm settle && mkfs.vfat -F32 /dev/vda1'

echo "=== First install: arch-a on /dev/vda2 (also partitions the disk) ==="
drive_install \
    "$MOUNT_HOST && $PARTED && ./install.sh -b /dev/vda1 -n arch-a /dev/vda2" \
    "$QEMU_9P"

echo
echo "=== Second install: arch-b on /dev/vda3 (reuses the ESP) ==="
drive_install \
    "$MOUNT_HOST && ./install.sh -b /dev/vda1 -n arch-b /dev/vda3" \
    "$QEMU_9P"

echo
echo "=== Boot menu check: both UKIs visible in systemd-boot ==="
find_ovmf
drive_menu_check "$DISK" "arch-a" "arch-b"
report $?
