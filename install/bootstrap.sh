#!/bin/bash

usage() {
    echo "TODO"
    exit $1
}

confirm() {
    read -p "Are you sure? [Y/n] " answer
    case "$answer" in
        [yY][eE][sS]|[yY])
	    ;;
	*)
	    echo "Quitting..."
	    exit 0
	    ;;
    esac
}

while getopts 'e:h' arg; do
    case "${arg}" in
        e) erase="${OPTARG}" ;;
        h) usage 0 ;;
        *)
           echo "Invalid argument '${arg}'"
           usage 1
           ;;
    esac
done
shift $((OPTIND -1))

target=$1

if [ -z "$target" ]; then
    usage 1
fi

# Confirm the target.
echo "Bootstrapping $target, this will format the device."

# Warn users about erase time.
if [ -n "$erase" ]; then
    echo "Erasing $target with $erase, this can take a while."
fi

# Display some information about the target device.
lsblk $target 

confirm
# From this point on we don't ask the user for anything.

if [ -n "$erase" ]; then
    dd if=$erase of=$target status=progress
fi

fdisk $target << EOF
g
n


+512M
t
1
n



p
w
EOF
