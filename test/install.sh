#!/bin/bash
#
# End-to-end install test. Single-boot by default (one LUKS root + ESP,
# UKI named "arch"); -d switches to dual-boot (arch-a + arch-b sharing
# one ESP). After install, boots the result under OVMF and verifies the
# expected UKI(s) appear in systemd-boot's menu.
#
# Two install drivers:
#   default  Host-driven: attach a raw image as a loopback device and
#            run format.sh + install.sh directly on the host. No QEMU
#            during the install phase, no ISO needed for that phase
#            either; QEMU only comes in at the end for the boot/menu
#            check. Fast iteration loop on the installer scripts.
#   -i       In-VM: boot the ISO and run the installer baked into it
#            at /root/. End-to-end test of what users get when they
#            `dd` the image. CI runs with -i (single + dual matrix).
#
# Add -n to disable the guest NIC (-nic none) and exercise the offline
# install path. Pairs with -i since the ISO has an offline repo baked
# in alongside install.sh; in default mode the host's working tree has
# no offline-repo, so -n there only affects the menu-check VM.
#
# Default mode requirements:
#   - root via sudo (losetup, cryptsetup, mount, pacstrap)
#   - Arch host (or Arch container) with arch-install-scripts, gptfdisk,
#     cryptsetup, dosfstools, e2fsprogs
#
# Common requirements: qemu-system-x86, qemu-img, expect, ovmf
# (-i additionally needs libarchive/bsdtar, blkid for ISO kernel extract.)
#
# Usage:
#   ./test/install.sh                  # single, host-driven
#   ./test/install.sh -d               # dual, host-driven
#   ./test/install.sh -i               # single, in-VM (most recent ISO)
#   ./test/install.sh -i -d            # dual, in-VM
#   ./test/install.sh -i out/some.iso  # in-VM, specific ISO
#   ./test/install.sh -i -n            # in-VM, offline (no NIC)
#
# Env:
#   LUKS_PASSPHRASE  Passphrase fed to cryptsetup (default: installtest)
#   DISK_SIZE        Test disk size, qemu-img syntax
#                    (default: 8G single, 16G dual)
#   TIMEOUT          Seconds for prompt-style expect waits (default: 10).
#                    [-i only]
#   LONG_TIMEOUT     Seconds for slow waits — cold boot, pacstrap
#                    completion (default: 1800). [-i only]
#   INTERACTIVE      Set to 1 to attach to the VM after install completes
#                    [-i only]
#   KEEP_DISK        Set to 1 to copy the disk to ./test-disk.qcow2 on exit
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=test/lib.sh
source "$SCRIPT_DIR/test/lib.sh"

iso_installer=0
nic_none=0
dual=0
while getopts 'idnh' arg; do case "$arg" in
    i) iso_installer=1 ;;
    d) dual=1 ;;
    n) nic_none=1 ;;
    h) echo "Usage: install.sh [-i] [-d] [-n] [<iso>]"; exit 0 ;;
    *) echo "Usage: install.sh [-i] [-d] [-n] [<iso>]" >&2; exit 1 ;;
esac done
shift $((OPTIND - 1))

# Disk size auto-scales with mode but the env var still wins.
if [ "$dual" = 1 ]; then
    DISK_SIZE=${DISK_SIZE:-16G}
else
    DISK_SIZE=${DISK_SIZE:-8G}
fi

# Mode-specific bits: format.sh specs, install.sh invocations, expected
# menu entries. Single uses install.sh's default UKI name ("arch"); dual
# uses arch-a / arch-b so the two UKIs can coexist on one ESP.
if [ "$dual" = 1 ]; then
    LAYOUT="single boot disabled — dual boot (arch-a + arch-b)"
    FORMAT_SPECS=(-p boot -p luks-ext4:8GiB -p luks-ext4)
    LUKS_COUNT=2
    MENU_NAMES=(arch-a arch-b)
else
    LAYOUT="single boot (arch)"
    FORMAT_SPECS=(-p boot -p luks-ext4)
    LUKS_COUNT=1
    MENU_NAMES=(arch)
fi

check_deps
find_ovmf  # the menu check needs OVMF in either mode

if [ "$iso_installer" = 1 ]; then
    if [ $# -gt 0 ] && [ -f "$1" ]; then
        resolve_iso "$1"
    else
        resolve_iso ""
    fi

    echo "ISO:      $ISO"
    echo "Mode:     in-VM install via bundled format.sh + install.sh"
    echo "Layout:   $LAYOUT"
    echo "Network:  $([ "$nic_none" = 1 ] && echo 'disabled (-nic none, offline test)' || echo 'enabled (default user-mode)')"
    echo "OVMF:     $OVMF_CODE${OVMF_VARS_TEMPLATE:+ + $OVMF_VARS_TEMPLATE}"

    prepare_qemu_inputs

    echo "Disk:     $DISK ($DISK_SIZE)"
    echo "Log:      $LOG"
    echo

    QEMU_EXTRA=""
    [ "$nic_none" = 1 ] && QEMU_EXTRA="-nic none"

    # $PART_N / $MAPPER_N expand inside the guest after sourcing /tmp/parts.env.
    # shellcheck disable=SC2016
    INSTALL_CMD="./format.sh -k ${FORMAT_SPECS[*]} /dev/vda > /tmp/parts.env"
    # shellcheck disable=SC2016
    INSTALL_CMD+=' && . /tmp/parts.env'
    if [ "$dual" = 1 ]; then
        # shellcheck disable=SC2016
        INSTALL_CMD+=' && ./install.sh -b "$PART_1" -n arch-a "$MAPPER_2"'
        # shellcheck disable=SC2016
        INSTALL_CMD+=' && ./install.sh -b "$PART_1" -n arch-b "$MAPPER_3"'
    else
        # shellcheck disable=SC2016
        INSTALL_CMD+=' && ./install.sh -b "$PART_1" "$MAPPER_2"'
    fi

    drive_install "$LUKS_COUNT" "$INSTALL_CMD" "$QEMU_EXTRA"

    echo
    echo "=== Boot menu check: $LAYOUT ==="
    drive_menu_check "$DISK" "${MENU_NAMES[@]}"
    report $?
    exit 0
fi

###############################################################################
# Default mode: host-driven loopback install.

echo "Mode:     host-driven install via loopback device"
echo "Layout:   $LAYOUT"
echo "OVMF:     $OVMF_CODE${OVMF_VARS_TEMPLATE:+ + $OVMF_VARS_TEMPLATE}"

setup_workdir
DISK="$WORK/disk.qcow2"

echo "Work:     $WORK"
echo "Size:     $DISK_SIZE"
echo "Log:      $LOG"
echo

# Prompt for sudo once, then keep the timestamp alive in the background
# so a long pacstrap doesn't expire it and trigger a second prompt
# halfway through the run (which often arrives unexpectedly and gets
# mis-typed). The keepalive watches its parent's PID and exits on its
# own if we die abnormally (SIGKILL, OOM) — without that watchdog it
# would otherwise leak past the script and keep refreshing sudo until
# reboot. cleanup_loop also kills it on normal exit for faster teardown.
sudo -v
PARENT=$$
( while kill -0 "$PARENT" 2>/dev/null && sudo -n -v 2>/dev/null; do
      sleep 50
  done ) &
SUDO_KEEPALIVE_PID=$!

LOOP=
declare -a MAPPERS=()

cleanup_loop() {
    set +e
    [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    local m mnts mnt
    for m in "${MAPPERS[@]}"; do
        mnts=$(awk -v dev="$m" '$1 == dev {print $2}' /proc/mounts | sort -r)
        for mnt in $mnts; do sudo umount "$mnt"; done
        sudo cryptsetup luksClose "$(basename "$m")" 2>/dev/null
    done
    [ -n "$LOOP" ] && sudo losetup -d "$LOOP" 2>/dev/null
    cleanup_workdir
}
trap cleanup_loop EXIT

RAW="$WORK/test-disk.img"
KEY="$WORK/luks.key"

truncate -s "$DISK_SIZE" "$RAW"
(umask 077; printf '%s' "$PASSPHRASE" > "$KEY")

LOOP=$(sudo losetup -fP --show "$RAW")
echo "Loop:     $LOOP"
echo

# format.sh prints PART_N / MAPPER_N assignments to stdout; -y skips the
# confirm prompt and -K feeds the LUKS passphrase from a file so nothing
# blocks on a TTY.
eval "$(sudo "$SCRIPT_DIR/format.sh" -y -K "$KEY" -k "${FORMAT_SPECS[@]}" "$LOOP")"

if [ "$dual" = 1 ]; then
    MAPPERS=("$MAPPER_2" "$MAPPER_3")
    sudo "$SCRIPT_DIR/install.sh" -b "$PART_1" -n arch-a "$MAPPER_2"
    sudo "$SCRIPT_DIR/install.sh" -b "$PART_1" -n arch-b "$MAPPER_3"
else
    MAPPERS=("$MAPPER_2")
    sudo "$SCRIPT_DIR/install.sh" -b "$PART_1" "$MAPPER_2"
fi

# Tear down the live device side before booting the result. We do this
# explicitly (rather than rely on cleanup_loop) so the boot helper sees
# a clean disk image with nothing else holding the partitions open.
for m in "${MAPPERS[@]}"; do
    sudo cryptsetup luksClose "$(basename "$m")"
done
MAPPERS=()
sudo losetup -d "$LOOP"
LOOP=

# qcow2 is what drive_menu_check expects; converting also frees the raw
# file's space (qcow2 stores only allocated extents).
qemu-img convert -O qcow2 "$RAW" "$DISK"
rm -f "$RAW"

echo
echo "=== Boot menu check: $LAYOUT ==="
drive_menu_check "$DISK" "${MENU_NAMES[@]}"
report $?
