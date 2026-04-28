#!/bin/bash
#
# Boot the ISO but run install.sh from the local repo (mounted via 9p),
# so you can iterate on install.sh / rootfs / packages.txt without
# rebuilding the ISO each time. The ISO is still used for its kernel,
# initramfs, and live system.
#
# Requires: qemu-system-x86, qemu-img, libarchive (bsdtar), expect
#
# Usage:
#   ./test-install-local.sh                            # most recent ISO in out/
#   ./test-install-local.sh out/some.iso               # specific ISO
#   ./test-install-local.sh out/some.iso -n arch-test  # extra args to install.sh
#
# Env:
#   LUKS_PASSPHRASE  Passphrase fed to cryptsetup (default: installtest)
#   DISK_SIZE        Test disk size, qemu-img syntax (default: 8G)
#   TIMEOUT          Seconds for any single expect step (default: 600)
#   INTERACTIVE      Set to 1 to attach to the VM after install completes
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=test/lib.sh
source "$SCRIPT_DIR/test/lib.sh"

check_deps

if [ $# -gt 0 ] && [ -f "$1" ]; then
    resolve_iso "$1"
    shift
else
    resolve_iso ""
fi
INSTALL_ARGS="${*:-/dev/vda}"

echo "ISO:      $ISO (live system only; installer comes from $SCRIPT_DIR)"
echo "Mode:     local installer (project tree shared via 9p, read-only)"
echo "Args:     ./install.sh $INSTALL_ARGS"

prepare_qemu_inputs

echo "Disk:     $DISK ($DISK_SIZE)"
echo "Log:      $LOG"
echo

# Share the project root into the guest read-only via virtio-9p, then
# chain through mount + cd + install in a single command line.
QEMU_9P="-virtfs local,path=$SCRIPT_DIR,mount_tag=hostshare,security_model=none,readonly=on"
INSTALL_CMD="mkdir -p /mnt/host && mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/host && cd /mnt/host && ./install.sh $INSTALL_ARGS"

drive_install "$INSTALL_CMD" "$QEMU_9P"
report $?
