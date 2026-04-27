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

Running the installer script will repurpose the target device to be a working
Arch Linux installation.

TODO: Read only installs.
TODO: Allow pacman mirror from disk (for offline installs).

```sh
./install.sh <device>

# Example:
./install.sh /dev/sda
```

The installer formats `<device>` as GPT with a 512 MB ESP and a LUKS-encrypted
root, then drops a Unified Kernel Image at `/efi/EFI/Linux/arch.efi` and
installs systemd-boot. Microcode is selected from `/proc/cpuinfo` so only the
matching `intel-ucode` or `amd-ucode` package lands on disk.

### Dual-boot

Use `-b <esp>` to reuse an existing EFI System Partition (e.g. one already
shared with Windows or another Arch install). In this mode `<device>` is
treated as the **root partition**, not a whole disk: the installer makes no
changes to the GPT and the existing loader configuration on the ESP is
preserved.

Use `-n <name>` to pick the UKI filename (default `arch`). Two Arch installs
sharing one ESP need distinct names so their UKIs don't collide in
`$ESP/EFI/Linux/`. The same name also feeds the UKI's embedded
`PRETTY_NAME` so each install shows up as `Arch Linux (<name>)` in the
systemd-boot menu instead of blending into a sea of identical entries.

```sh
# Install alongside Windows on /dev/sda. /dev/sda1 is the existing ESP,
# /dev/sda3 is a pre-created LUKS-bound partition for our root.
./install.sh -b /dev/sda1 /dev/sda3

# Two Arch installs sharing one ESP:
./install.sh -b /dev/sda1 -n arch-work /dev/sda2
./install.sh -b /dev/sda1 -n arch-home /dev/sda3
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
