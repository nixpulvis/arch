#!/bin/bash
#
# Boot an already-installed qcow2 disk under OVMF and verify the system
# unlocks LUKS, reaches a login prompt, and yields a working shell.
#
# Pair with one of the install tests (which create the disk):
#   KEEP_DISK=1 ./test-install-local.sh   # produces ./test-disk.qcow2
#   ./test-boot.sh                        # boots ./test-disk.qcow2
#
# Or pass an explicit path:
#   ./test-boot.sh /path/to/disk.qcow2
#
# Requires: qemu-system-x86, expect, edk2-ovmf (Arch) or ovmf (Debian/Ubuntu)
#
# Env:
#   LUKS_PASSPHRASE  Passphrase for the install (default: installtest)
#   TIMEOUT          Seconds for any single expect step (default: 600)
#   INTERACTIVE      Set to 1 to attach to the VM after the boot succeeds
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test-install-lib.sh
source "$SCRIPT_DIR/test-install-lib.sh"

DISK_PATH=${1:-$SCRIPT_DIR/test-disk.qcow2}

if [ ! -f "$DISK_PATH" ]; then
    echo "ERROR: disk not found: $DISK_PATH"
    echo "Run KEEP_DISK=1 ./test-install-local.sh first to produce one,"
    echo "or pass an explicit qcow2 path as the first argument."
    exit 1
fi

check_deps
find_ovmf
setup_workdir

echo "Disk:     $DISK_PATH"
echo "OVMF:     $OVMF_BIOS"
echo "Log:      $LOG"
echo

drive_boot "$DISK_PATH"
report $?
