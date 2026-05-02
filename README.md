# Arch Linux

TODO: Quick explaination of Arch, and why we use it.

## Setup

This glorified script can be retreived from GitHub directly.

```sh
# Using `git`
git clone https://github.com/nixpulvis/arch

# Using `wget` (for systems without `git`)
wget https://github.com/nixpulvis/arch/archive/master.tar.gz -O arch-master.tar.gz
tar -xzvf arch-master.tar.gz
```

## Install

Installation is two scripts: `format.sh` does the disk surgery
(partitions, LUKS, filesystems), `install.sh` does the OS install.
Splitting them keeps the destructive step explicit and lets one
`format.sh` set up an ESP plus N root slots for as many installs as you
want.

TODO: Read only installs.
TODO: Allow pacman mirror from disk (for offline installs).

```sh
# Format /dev/sda as ESP + LUKS-ext4 root, leave the LUKS volume open (-k).
eval "$(./format.sh -k -p boot -p luks-ext4 /dev/sda)"

# Install onto the opened root, using the ESP we just created.
./install.sh -b "$PART_1" "$MAPPER_2"
```

`format.sh` accepts repeated `-p <spec>` flags. Specs:

- `boot[:<size>]`: ESP (fat32, 512 MiB default)
- `<fstype>[:<size>]`: plain ext4/exfat/...
- `luks-<fstype>[:<size>]`: LUKS-wrapped fs

Omit the size on the last `-p` to use remaining space. `-k` keeps LUKS
volumes open after formatting (so `install.sh` can use them); without
`-k` they're closed and you re-open them yourself.

`install.sh` drops a Unified Kernel Image at `/efi/EFI/Linux/arch.efi`
and installs systemd-boot. Microcode is selected from `/proc/cpuinfo`
so only the matching `intel-ucode` or `amd-ucode` package lands on
disk.

### Dual-boot

`-b <esp>` lets `install.sh` reuse an existing EFI System Partition (e.g.
one already shared with Windows or another Arch install). The installer
makes no changes to the GPT and the existing loader configuration on
the ESP is preserved.

`-n <name>` picks the UKI filename (default `arch`). Two Arch installs
sharing one ESP need distinct names so their UKIs don't collide in
`$ESP/EFI/Linux/`. The same name also feeds the UKI's embedded
`PRETTY_NAME` so each install shows up as `Arch Linux (<name>)` in the
systemd-boot menu instead of blending into a sea of identical entries.

```sh
# Two Arch installs sharing one ESP. format.sh creates the ESP plus two
# 8 GiB LUKS roots in one shot:
eval "$(./format.sh -k -p boot -p luks-ext4:8GiB -p luks-ext4 /dev/sda)"
./install.sh -b "$PART_1" -n arch-work "$MAPPER_2"
./install.sh -b "$PART_1" -n arch-home "$MAPPER_3"
```

If the existing ESP already has systemd-boot, the installer runs
`bootctl update` (which is a no-op if the existing copy is newer than ours).
Otherwise it runs `bootctl install`, which adds systemd-boot alongside any
existing bootloader. systemd-boot auto-discovers Windows Boot Manager on the
same ESP; GRUB-based dual-boots are not yet covered (see PLAN-dual-boot.md).

To remove one of two coexisting Arch installs, delete its UKI:

```sh
rm /efi/EFI/Linux/arch-work.efi /efi/EFI/Linux/arch-work-fallback.efi
```

## ISO

Build a bootable ISO with the installer baked in. Requires `archiso`.

```sh
pacman -S archiso
sudo ./build.sh
```

Write to a USB drive:

```sh
dd if=out/archlinux-nixpulvis-*.iso of=/dev/sdX bs=4M status=progress
```

Test in QEMU:

```sh
pacman -S qemu-system-x86 qemu-ui-gtk qemu-img
```

Boot the installer ISO:

```sh
qemu-system-x86_64 \
  -cdrom out/archlinux-nixpulvis-*.iso \
  -boot d \
  -m 2G \
  -enable-kvm \
  -display gtk
```

Test the installer against a virtual disk:

```sh
qemu-img create -f qcow2 test-disk.qcow2 20G
qemu-system-x86_64 \
  -cdrom out/archlinux-nixpulvis-*.iso \
  -boot d \
  -m 2G \
  -enable-kvm \
  -display gtk \
  -drive file=test-disk.qcow2,format=qcow2
```

Test offline install (no network):

```sh
qemu-system-x86_64 \
  -cdrom out/archlinux-nixpulvis-*.iso \
  -boot d \
  -m 2G \
  -enable-kvm \
  -display gtk \
  -drive file=test-disk.qcow2,format=qcow2 \
  -nic none
```
