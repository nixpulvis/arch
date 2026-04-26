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

TODO: Dual-boot.
TODO: Read only installs.
TODO: Allow pacman mirror from disk (for offline installs).

```sh
./install.sh <device>

# Example:
./install.sh /dev/sda
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
