# shellcheck shell=bash
# Shared helpers for test-install-{iso,local}.sh. Source; do not execute.
#
# The wrapper scripts choose where install.sh comes from (baked into the
# ISO vs. mounted from the host); the boot, prompt-driving, and
# pass/fail bookkeeping is identical and lives here.

# These globals must be set by the caller before sourcing helpers:
#   SCRIPT_DIR  — repo root (for finding ISOs and the project tree)
# These get set during run:
#   ISO, WORK, DISK, LOG, KERNEL, INITRD, LABEL

PASSPHRASE=${LUKS_PASSPHRASE:-installtest}
DISK_SIZE=${DISK_SIZE:-8G}
TIMEOUT=${TIMEOUT:-600}
INTERACTIVE_MODE=${INTERACTIVE:-0}

check_deps() {
    for cmd in expect bsdtar qemu-system-x86_64 qemu-img blkid; do
        command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
    done
}

# Locate UEFI firmware for booting an installed disk. Sets OVMF_BIOS.
find_ovmf() {
    for p in \
        /usr/share/edk2/x64/OVMF.4m.fd \
        /usr/share/edk2-ovmf/x64/OVMF.4m.fd \
        /usr/share/edk2-ovmf/x64/OVMF.fd \
        /usr/share/OVMF/OVMF_CODE.fd; do
        if [ -f "$p" ]; then
            OVMF_BIOS=$p
            return
        fi
    done
    echo "ERROR: OVMF firmware not found. Install edk2-ovmf (Arch) or ovmf (Debian/Ubuntu)."
    exit 1
}

# Pick the newest ISO under $SCRIPT_DIR/out, or use $1 if it's a file.
# Sets ISO.
resolve_iso() {
    if [ -n "$1" ] && [ -f "$1" ]; then
        ISO=$1
        return
    fi
    ISO=$(find "$SCRIPT_DIR/out" -maxdepth 1 -name 'archlinux-nixpulvis-*.iso' \
              -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
    if [ -z "$ISO" ]; then
        echo "ERROR: no ISO found in $SCRIPT_DIR/out/"
        exit 1
    fi
}

# Set up $WORK with a cleanup trap that honors KEEP_DISK. Sets WORK, LOG.
setup_workdir() {
    # Put WORK in the project tree, not /tmp — qcow2 disks grow into the
    # GB range during install and /tmp is often a small tmpfs.
    WORK=$(mktemp -d --tmpdir="$SCRIPT_DIR")
    LOG="$WORK/serial.log"
    trap cleanup_workdir EXIT
}

cleanup_workdir() {
    if [ "${KEEP_DISK:-0}" = "1" ] && [ -n "${DISK:-}" ] && [ -f "$DISK" ]; then
        cp "$DISK" "$SCRIPT_DIR/test-disk.qcow2"
        echo "Disk preserved at: $SCRIPT_DIR/test-disk.qcow2"
    fi
    [ -n "${WORK:-}" ] && rm -rf "$WORK"

    # Drain any escape-sequence responses (e.g. cursor-position reports
    # from agetty/login) that leaked through -serial stdio and are
    # sitting in the terminal's input buffer waiting to be "typed" at
    # the next shell prompt.
    if [ -t 0 ]; then
        local _drain
        # shellcheck disable=SC2034
        read -rs -t 0.1 -N 1024 _drain || true
        stty sane 2>/dev/null || true
    fi
}

# Set up $WORK, create the test disk, and extract the live kernel +
# initramfs from the ISO so we can append console=ttyS0 at boot.
# Sets WORK, DISK, LOG, KERNEL, INITRD, LABEL.
prepare_qemu_inputs() {
    setup_workdir
    DISK="$WORK/disk.qcow2"
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null

    bsdtar -xf "$ISO" -C "$WORK" \
        arch/boot/x86_64/vmlinuz-linux \
        arch/boot/x86_64/initramfs-linux.img
    KERNEL="$WORK/arch/boot/x86_64/vmlinuz-linux"
    INITRD="$WORK/arch/boot/x86_64/initramfs-linux.img"
    LABEL=$(blkid -s LABEL -o value "$ISO")
}

# Drive QEMU + install.sh end-to-end.
# Args:
#   $1 = command line to run inside the VM (must invoke install.sh and
#        eventually return to the shell prompt; the helper appends an
#        outcome marker so success/failure is unambiguous)
#   $2 = (optional) additional QEMU args, passed verbatim into the spawn
drive_install() {
    local install_cmd=$1
    local extra_qemu_args=${2:-}

    expect <(cat <<EXPECT
set timeout $TIMEOUT
log_file -a "$LOG"
log_user 1

set enter_prompt   {Enter (LUKS )?passphrase}
set verify_prompt  {(Verify|Repeat) passphrase}
set yes_prompt     {Type 'yes' in capital letters}

proc fail {step} {
    global expect_out
    puts "\n=== TIMEOUT at: \$step ==="
    puts "--- last 2KB of serial buffer ---"
    puts \$expect_out(buffer)
    exit 4
}

spawn qemu-system-x86_64 \\
    -kernel "$KERNEL" \\
    -initrd "$INITRD" \\
    -append "archisobasedir=arch archisolabel=$LABEL console=ttyS0" \\
    -cdrom "$ISO" \\
    -m 4G -smp 4 \\
    -enable-kvm -cpu host \\
    -display none \\
    -serial stdio \\
    -monitor none \\
    -no-reboot \\
    -drive file=$DISK,format=qcow2,if=virtio \\
    $extra_qemu_args

expect {
    "archiso login:" { }
    timeout { fail "login prompt" }
}
send -- "root\n"

expect {
    -re {[#\$] $} { }
    timeout { fail "root shell prompt" }
}
send -- "$install_cmd && echo __INSTALL_OK__ || echo __INSTALL_FAIL__\n"

expect {
    "Are you sure?" { }
    timeout { fail "install.sh confirm prompt" }
}
send -- "y\n"

expect {
    -re \$yes_prompt { }
    timeout { fail "cryptsetup YES prompt" }
}
send -- "YES\n"

expect {
    -re \$enter_prompt { }
    timeout { fail "cryptsetup luksFormat passphrase prompt" }
}
# 1s sleep avoids racing cryptsetup's tcsetattr (same fix as drive_boot).
sleep 1
send -- "$PASSPHRASE\n"
puts "\n>>> sent luksFormat passphrase, waiting for verify (Argon2id KDF takes a moment)..."

expect {
    -re \$verify_prompt { }
    timeout { fail "cryptsetup verify-passphrase prompt" }
}
sleep 1
send -- "$PASSPHRASE\n"
puts "\n>>> sent verify, waiting for luksFormat to finish and luksOpen prompt..."

expect {
    -re \$enter_prompt { }
    timeout { fail "cryptsetup luksOpen passphrase prompt" }
}
sleep 1
send -- "$PASSPHRASE\n"
puts "\n>>> sent luksOpen passphrase, waiting for install to finish (pacstrap may take a few minutes)..."

expect {
    "__INSTALL_OK__"   { }
    "__INSTALL_FAIL__" { puts "\n=== install.sh exited non-zero ==="; exit 2 }
    timeout            { fail "install completion marker" }
}

if {$INTERACTIVE_MODE} {
    puts "\n=== INTERACTIVE MODE: ^] to detach the QEMU monitor ==="
    interact
} else {
    expect {
        -re {[#\$] $} { }
        timeout { fail "post-install shell prompt" }
    }
    # reboot -f skips systemd shutdown (which can hang on the 9p
    # unmount in local mode) and calls reboot(2) directly; QEMU's
    # -no-reboot turns the guest reboot into process exit.
    send -- "sync; reboot -f\n"
    expect eof
}
EXPECT
)
}

# Boot an installed qcow2 disk under OVMF, drive the LUKS unlock prompt,
# and verify the system reaches a login prompt and shell.
# Args:
#   $1 = path to the installed qcow2 disk (read-write; will be modified)
drive_boot() {
    local disk=$1

    expect <(cat <<EXPECT
set timeout $TIMEOUT
log_file -a "$LOG"
log_user 1

set enter_prompt {Enter (LUKS )?passphrase|Please enter passphrase}

proc fail {step} {
    global expect_out
    puts "\n=== TIMEOUT at: \$step ==="
    puts "--- last 2KB of serial buffer ---"
    puts \$expect_out(buffer)
    exit 4
}

# SMBIOS Type 11 string is read by systemd-stub at boot and appended to
# the kernel cmdline — lets us route output to serial without modifying
# the production UKI's baked cmdline.
spawn qemu-system-x86_64 \\
    -bios "$OVMF_BIOS" \\
    -m 4G -smp 4 \\
    -enable-kvm -cpu host \\
    -display none \\
    -serial stdio \\
    -monitor none \\
    -no-reboot \\
    -smbios type=11,value=io.systemd.stub.kernel-cmdline-extra=console=ttyS0,,115200\ loglevel=7\ systemd.show_status=yes\ systemd.log_target=kmsg \\
    -drive file=$disk,format=qcow2,if=virtio

expect {
    -re \$enter_prompt { }
    timeout { fail "LUKS unlock prompt" }
}

# In INTERACTIVE mode, hand off BEFORE sending the passphrase so the
# user can type it manually and observe what happens — useful when the
# auto-send appears to hang (lets us isolate whether cryptsetup itself
# is the problem or our send timing is).
if {$INTERACTIVE_MODE} {
    puts "\n=== INTERACTIVE MODE: console is yours. Type the LUKS"
    puts "    passphrase ($PASSPHRASE) and watch what happens."
    puts "    ^] to detach the QEMU monitor. ==="
    interact
    exit 0
}

# Wait for cryptsetup to finish printing the prompt and call tcsetattr
# to disable echo. Sending immediately after the regex match races that
# setup — the chars hit the TTY in canonical+echo mode and cryptsetup
# never sees them as a complete passphrase.
sleep 1
send -- "$PASSPHRASE\n"
puts "\n>>> sent LUKS passphrase, waiting for login prompt..."

expect {
    "login:" { }
    timeout { fail "login prompt" }
}
send -- "root\n"

# passwd -d removes root's password; agetty/login lets us straight in.
# But some configurations still emit a Password: prompt (and accept empty).
expect {
    "Password:"           { send -- "\n"; exp_continue }
    -re {[#\$] $}         { }
    timeout               { fail "shell prompt after login" }
}

send -- "echo __BOOT_OK__\n"
expect {
    "__BOOT_OK__" { }
    timeout       { fail "boot success marker" }
}

send -- "sync; reboot -f\n"
expect eof
EXPECT
)
}

# Boot the disk under OVMF just long enough to capture systemd-boot's
# menu, then check the serial log for each expected entry name.
# Args:
#   $1 = path to the qcow2 disk
#   $2... = strings that must each appear in the menu output (e.g. UKI
#           filenames "arch-a" "arch-b", or display titles)
drive_menu_check() {
    local disk=$1
    shift
    local expected=("$@")
    local capture="$WORK/menu.log"

    expect <(cat <<EXPECT
log_file -a "$capture"
log_user 1

spawn qemu-system-x86_64 \\
    -bios "$OVMF_BIOS" \\
    -m 4G -smp 4 \\
    -enable-kvm -cpu host \\
    -display none \\
    -serial stdio \\
    -monitor none \\
    -no-reboot \\
    -smbios type=11,value=io.systemd.stub.kernel-cmdline-extra=console=ttyS0,,115200 \\
    -drive file=$disk,format=qcow2,if=virtio

# Capture ~15 seconds of output. The OVMF→systemd-boot handoff takes a
# few seconds; the menu renders, then auto-boot fires after 5s. By 15s
# we've seen the menu and possibly the start of one entry's boot, which
# is fine — we only care about what was in the menu text.
set timeout 15
expect timeout { }

# Close the spawned process to stop QEMU early.
catch { close }
catch { wait -nowait }
EXPECT
)

    echo
    local missing=()
    local name
    for name in "${expected[@]}"; do
        if grep -q -- "$name" "$capture"; then
            echo "  found in menu: $name"
        else
            echo "  MISSING from menu: $name"
            missing+=("$name")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo
        echo "FAIL: menu check missing ${#missing[@]} entry/entries: ${missing[*]}"
        echo "Captured menu output saved to test-menu.log:"
        cp "$capture" "$SCRIPT_DIR/test-menu.log"
        return 5
    fi
    echo "  all $((${#expected[@]})) expected entries present"
    return 0
}

# Print PASS/FAIL summary based on the expect exit status. On failure,
# tails the serial log and copies it to ./test-install.log for inspection.
report() {
    local status=$1
    case $status in
        0)  echo; echo "PASS" ;;
        2)  echo; echo "FAIL: install.sh exited non-zero" ;;
        4)  echo; echo "FAIL: timed out waiting for an expected prompt" ;;
        *)  echo; echo "FAIL: status $status" ;;
    esac

    if [ "$status" -ne 0 ]; then
        cp "$LOG" "$SCRIPT_DIR/test-install.log"
        echo "Full serial log saved to test-install.log"
        echo "--- last 50 lines ---"
        tail -50 "$LOG"
        exit 1
    fi
}
