#!/bin/bash
#
# Boot test. Mode is dispatched by file extension of the argument:
#
#   *.iso  → boot the live ISO directly (smoke test that the built ISO
#            is bootable; no install, no LUKS).
#   else   → boot an installed qcow2 disk under OVMF, drive the LUKS
#            unlock prompt, and verify a working shell.
#
# Examples:
#   ./test/boot.sh out/some.iso          # live ISO smoke test
#   ./test/boot.sh test-disk.qcow2       # installed disk
#
# Requires: qemu-system-x86, expect, blkid, bsdtar (for ISO mode), and
#           edk2-ovmf / ovmf (for installed-disk mode).
#
# Env:
#   LUKS_PASSPHRASE  Passphrase for installed disk mode (default: installtest)
#   TIMEOUT          Seconds for any single expect step (default: 600)
#   INTERACTIVE      Set to 1 to attach to the VM
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=test/lib.sh
source "$SCRIPT_DIR/test/lib.sh"

if [ $# -ne 1 ]; then
    echo "Usage: $0 <path-to-iso-or-qcow2>"
    exit 1
fi
TARGET=$1

if [ ! -f "$TARGET" ]; then
    echo "ERROR: file not found: $TARGET"
    exit 1
fi

case "$TARGET" in
    *.iso)
        check_deps
        ISO=$TARGET
        setup_workdir
        extract_iso_kernel
        echo "ISO:      $ISO"
        echo "Mode:     live ISO smoke test"
        echo "Log:      $LOG"
        echo
        drive_boot_iso
        ;;
    *)
        check_deps
        find_ovmf
        setup_workdir
        echo "Disk:     $TARGET"
        echo "OVMF:     $OVMF_BIOS"
        echo "Log:      $LOG"
        echo
        drive_boot "$TARGET"
        ;;
esac
report $?
