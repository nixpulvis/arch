# shellcheck shell=bash
# Shared helpers for the test/ scripts. Source; do not execute.
#
# Provides QEMU + expect plumbing for booting the live ISO, driving an
# in-VM install via expect prompts, booting an installed disk, and
# capturing systemd-boot's menu output. test/install.sh's host-driven
# default mode reuses only setup_workdir, find_ovmf, and drive_menu_check
# from here.

# These globals must be set by the caller before sourcing helpers:
#   SCRIPT_DIR: repo root (for finding ISOs and the project tree)
# These get set during run:
#   ISO, WORK, DISK, LOG, KERNEL, INITRD, LABEL

PASSPHRASE=${LUKS_PASSPHRASE:-installtest}
# DISK_SIZE is set by the caller (test/install.sh picks 8G/16G based
# on single vs dual layout); not defaulted here to avoid clobbering
# that decision when this lib is sourced first.
# TIMEOUT bounds expect waits on prompts that should arrive instantly
# (login, shell, cryptsetup prompts). Kept short so wedged runs fail
# fast. LONG_TIMEOUT bounds the steps that wait on real work: boot-up
# from cold and pacstrap completion. Each drive_* helper toggles
# between them around the relevant expect blocks.
TIMEOUT=${TIMEOUT:-30}
LONG_TIMEOUT=${LONG_TIMEOUT:-2400}
INTERACTIVE_MODE=${INTERACTIVE:-0}

# Use KVM where available (host == guest arch + /dev/kvm writable);
# fall back to TCG emulation otherwise. CI runners typically can't KVM.
if [ -w /dev/kvm ]; then
    KVM_FLAGS="-enable-kvm -cpu host"
else
    KVM_FLAGS=""
fi

check_deps() {
    for cmd in expect bsdtar qemu-system-x86_64 qemu-img blkid; do
        command -v "$cmd" >/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
    done
}

# Locate UEFI firmware for booting an installed disk. Sets OVMF_CODE and
# OVMF_VARS_TEMPLATE; the latter is empty for a unified image (loadable
# via -bios) and set to the template path for split firmware (needs
# pflash drives — use ovmf_qemu_args to assemble the right QEMU flags).
find_ovmf() {
    local candidates=(
        "/usr/share/edk2/x64/OVMF_CODE.4m.fd|/usr/share/edk2/x64/OVMF_VARS.4m.fd"
        "/usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd|/usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd"
        "/usr/share/edk2/x64/OVMF.4m.fd"
        "/usr/share/edk2-ovmf/x64/OVMF.4m.fd"
        "/usr/share/edk2-ovmf/x64/OVMF.fd"
        "/usr/share/OVMF/OVMF_CODE_4M.fd|/usr/share/OVMF/OVMF_VARS_4M.fd"
        "/usr/share/OVMF/OVMF_CODE.fd|/usr/share/OVMF/OVMF_VARS.fd"
    )
    local entry code vars
    for entry in "${candidates[@]}"; do
        code=${entry%%|*}
        vars=""
        [ "$entry" != "$code" ] && vars=${entry#*|}
        if [ -f "$code" ] && { [ -z "$vars" ] || [ -f "$vars" ]; }; then
            OVMF_CODE=$code
            OVMF_VARS_TEMPLATE=$vars
            return
        fi
    done
    echo "ERROR: OVMF firmware not found. Install edk2-ovmf (Arch) or ovmf (Debian/Ubuntu)."
    exit 1
}

# Emit the QEMU args for the located OVMF firmware. For split firmware,
# copies the VARS template into $WORK so the guest has a writable
# variable store (pflash requires write access even if we discard it).
# Requires WORK when split.
ovmf_qemu_args() {
    if [ -z "$OVMF_VARS_TEMPLATE" ]; then
        printf -- '-bios %s' "$OVMF_CODE"
        return
    fi
    local vars="$WORK/ovmf_vars.fd"
    cp --no-preserve=mode "$OVMF_VARS_TEMPLATE" "$vars"
    printf -- '-drive if=pflash,format=raw,readonly=on,file=%s -drive if=pflash,format=raw,file=%s' \
        "$OVMF_CODE" "$vars"
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
    # Put WORK in the project tree, not /tmp; qcow2 disks grow into the
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

# Extract the live kernel + initramfs from $ISO into $WORK so QEMU can
# boot directly with console=ttyS0 appended. Sets KERNEL, INITRD, LABEL.
# Requires WORK to be set (via setup_workdir).
extract_iso_kernel() {
    bsdtar -xf "$ISO" -C "$WORK" \
        arch/boot/x86_64/vmlinuz-linux \
        arch/boot/x86_64/initramfs-linux.img
    KERNEL="$WORK/arch/boot/x86_64/vmlinuz-linux"
    INITRD="$WORK/arch/boot/x86_64/initramfs-linux.img"
    LABEL=$(blkid -s LABEL -o value "$ISO")
}

# Set up $WORK, create the test disk, and extract the live kernel +
# initramfs from the ISO. Sets WORK, DISK, LOG, KERNEL, INITRD, LABEL.
prepare_qemu_inputs() {
    setup_workdir
    DISK="$WORK/disk.qcow2"
    qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
    extract_iso_kernel
}

# Drive QEMU through format.sh + install.sh end-to-end.
# Args:
#   $1 = number of LUKS partitions format.sh creates (drives that many
#        YES/passphrase/verify/open prompt sequences)
#   $2 = command line to run inside the VM. Must invoke format.sh and
#        install.sh in that order and finish with a marker (the helper
#        wraps the call to print __INSTALL_OK__ / __INSTALL_FAIL__).
#   $3 = (optional) additional QEMU args, passed verbatim into the spawn
drive_install() {
    local luks_count=$1
    local install_cmd=$2
    local extra_qemu_args=${3:-}

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
    $KVM_FLAGS \\
    -display none \\
    -serial stdio \\
    -monitor none \\
    -no-reboot \\
    -drive file=$DISK,format=qcow2,if=virtio \\
    $extra_qemu_args

# Cold boot to the archiso login prompt — minutes under TCG.
set timeout $LONG_TIMEOUT
expect {
    "archiso login:" { }
    timeout { fail "login prompt" }
}
set timeout $TIMEOUT
send -- "root\n"

expect {
    -re {[#\$] $} { }
    timeout { fail "root shell prompt" }
}
# Wrap \$install_cmd in Tcl braces so embedded \$VAR / " survive verbatim
# (the new flow has \$PART_1 / \$MAPPER_N referencing /tmp/parts.env in the
# guest); concatenate the marker tail in a normal Tcl string so \\n parses
# as a newline.
send -- {$install_cmd}
send -- " && echo __INSTALL_OK__ || echo __INSTALL_FAIL__\n"

# format.sh prompts once before doing anything destructive.
expect {
    "Are you sure?" { }
    timeout { fail "format.sh confirm prompt" }
}
send -- "y\n"

# Each LUKS partition: cryptsetup YES warning, luksFormat passphrase
# (with verify), then luksOpen passphrase. 1s sleeps avoid racing
# cryptsetup's tcsetattr; sending immediately after the regex match
# loses chars to canonical+echo mode.
for {set i 0} {\$i < $luks_count} {incr i} {
    expect {
        -re \$yes_prompt { }
        timeout { fail "cryptsetup YES prompt (luks #\$i)" }
    }
    send -- "YES\n"

    expect {
        -re \$enter_prompt { }
        timeout { fail "cryptsetup luksFormat passphrase (luks #\$i)" }
    }
    sleep 1
    send -- "$PASSPHRASE\n"
    puts "\n>>> sent luksFormat passphrase #\$i, waiting for verify..."

    expect {
        -re \$verify_prompt { }
        timeout { fail "cryptsetup verify-passphrase (luks #\$i)" }
    }
    sleep 1
    send -- "$PASSPHRASE\n"

    expect {
        -re \$enter_prompt { }
        timeout { fail "cryptsetup luksOpen passphrase (luks #\$i)" }
    }
    sleep 1
    send -- "$PASSPHRASE\n"
    puts "\n>>> sent luksOpen passphrase #\$i"
}

puts "\n>>> LUKS setup done, waiting for install(s) to finish (pacstrap may take a few minutes per install)..."

# pacstrap + bootctl + sync — minutes per install.
set timeout $LONG_TIMEOUT
expect {
    "__INSTALL_OK__"   { }
    "__INSTALL_FAIL__" { puts "\n=== install pipeline exited non-zero ==="; exit 2 }
    timeout            { fail "install completion marker" }
}
set timeout $TIMEOUT

if {$INTERACTIVE_MODE} {
    puts "\n=== INTERACTIVE MODE: ^] to detach the QEMU monitor ==="
    interact
} else {
    expect {
        -re {[#\$] $} { }
        timeout { fail "post-install shell prompt" }
    }
    # reboot -f skips systemd shutdown and calls reboot(2) directly;
    # QEMU's -no-reboot turns the guest reboot into process exit.
    send -- "sync; reboot -f\n"
    expect eof
}
EXPECT
)
}

# Boot the live ISO directly and verify it reaches the archiso login
# prompt, then a working shell. Used as a smoke test that the built ISO
# is bootable. Requires extract_iso_kernel to have populated KERNEL,
# INITRD, LABEL, and ISO.
drive_boot_iso() {
    # The whole helper waits on a cold boot; LONG_TIMEOUT throughout.
    expect <(cat <<EXPECT
set timeout $LONG_TIMEOUT
log_file -a "$LOG"
log_user 1

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
    $KVM_FLAGS \\
    -display none \\
    -serial stdio \\
    -monitor none \\
    -no-reboot

expect {
    "archiso login:" { }
    timeout { fail "archiso login prompt" }
}

if {$INTERACTIVE_MODE} {
    puts "\n=== INTERACTIVE MODE: console is yours. ^] to detach. ==="
    interact
    exit 0
}

send -- "root\n"
expect {
    -re {[#\$] $} { }
    timeout { fail "root shell prompt" }
}
send -- "sync; reboot -f\n"
expect eof
EXPECT
)
}

# Boot an installed qcow2 disk under OVMF, drive the LUKS unlock prompt,
# and verify the system reaches a login prompt and shell.
# Args:
#   $1 = path to the installed qcow2 disk (read-write; will be modified)
drive_boot() {
    local disk=$1
    local ovmf_args
    ovmf_args=$(ovmf_qemu_args)

    # Boot from cold (OVMF + initramfs + LUKS unlock + systemd) — slow
    # under TCG; use LONG_TIMEOUT throughout. Post-login waits would
    # normally be fast but the cost of a slow failure here is small.
    expect <(cat <<EXPECT
set timeout $LONG_TIMEOUT
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
# the kernel cmdline. Lets us route output to serial without modifying
# the production UKI's baked cmdline.
spawn qemu-system-x86_64 \\
    $ovmf_args \\
    -m 4G -smp 4 \\
    $KVM_FLAGS \\
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
# user can type it manually and observe what happens. Useful when the
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
# setup; the chars hit the TTY in canonical+echo mode and cryptsetup
# never sees them as a complete passphrase.
sleep 1
send -- "$PASSPHRASE\n"
puts "\n>>> sent LUKS passphrase, waiting for login prompt..."

expect {
    "login:" { }
    timeout { fail "login prompt" }
}
send -- "root\n"

# passwd -d removes root's password; login lets us straight in. Some
# configurations still emit "Password:"; accept empty in that case.
expect {
    "Password:"           { send -- "\n"; exp_continue }
    "Welcome to fish"     { }
    -re {[#\$] $}         { }
    timeout               { fail "shell startup after login" }
}

# Fish does terminal-capability queries at startup that race with any
# immediate send. Wait for it to settle before issuing reboot.
sleep 3
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
    local ovmf_args
    ovmf_args=$(ovmf_qemu_args)

    expect <(cat <<EXPECT
log_file -a "$capture"
log_user 1

spawn qemu-system-x86_64 \\
    $ovmf_args \\
    -m 4G -smp 4 \\
    $KVM_FLAGS \\
    -display none \\
    -serial stdio \\
    -monitor none \\
    -no-reboot \\
    -smbios type=11,value=io.systemd.stub.kernel-cmdline-extra=console=ttyS0,,115200 \\
    -drive file=$disk,format=qcow2,if=virtio

# Capture ~15 seconds of output. The OVMF to systemd-boot handoff takes
# a few seconds; the menu renders, then auto-boot fires after 5s. By 15s
# we've seen the menu and possibly the start of one entry's boot, which
# is fine; we only care about what was in the menu text.
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
