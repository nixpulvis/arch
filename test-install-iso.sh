#!/bin/bash
#
# Boot the ISO and run the install.sh that's baked into it. This is the
# end-to-end test of what users actually get when they `dd` the image.
#
# Requires: qemu-system-x86, qemu-img, libarchive (bsdtar), expect
#
# Usage:
#   ./test-install-iso.sh                           # most recent ISO in out/
#   ./test-install-iso.sh out/some.iso              # specific ISO
#   ./test-install-iso.sh out/some.iso -n arch-test # extra args to install.sh
#
# Env:
#   LUKS_PASSPHRASE  Passphrase fed to cryptsetup (default: installtest)
#   DISK_SIZE        Test disk size, qemu-img syntax (default: 8G)
#   TIMEOUT          Seconds for any single expect step (default: 600)
#   INTERACTIVE      Set to 1 to attach to the VM after install completes
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=test-install-lib.sh
source "$SCRIPT_DIR/test-install-lib.sh"

check_deps

if [ $# -gt 0 ] && [ -f "$1" ]; then
    resolve_iso "$1"
    shift
else
    resolve_iso ""
fi
INSTALL_ARGS="${*:-/dev/vda}"

echo "ISO:      $ISO"
echo "Mode:     bundled installer (./install.sh from /root in the live ISO)"
echo "Args:     ./install.sh $INSTALL_ARGS"

prepare_qemu_inputs

echo "Disk:     $DISK ($DISK_SIZE)"
echo "Log:      $LOG"
echo

drive_install "./install.sh $INSTALL_ARGS"
report $?
