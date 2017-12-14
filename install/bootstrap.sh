#!/bin/bash

usage() {
    echo "TODO"
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

TARGET=$1

# Confirm the target.
echo "Bootstrapping $TARGET, this will format the device."

# Warn users about erase time.
if [ -n "$erase" ]; then
    echo "Erasing $TARGET with $erase, this can take a while."
fi

# Display some information about the target device.
lsblk $TARGET 

confirm
