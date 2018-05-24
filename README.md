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
TODO: ISO creation.
TODO: Allow pacman mirror from disk (for offline installs).

```sh
./install.sh <device>

# Example:
./install.sh /dev/sda
```
