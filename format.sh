#!/bin/bash
#
# Clear a device's partition signatures and (optionally) lay out new
# partitions with filesystems / LUKS containers.
#
# Takes a list of -p specs and prints assignment lines to stdout for
# the caller to `eval`:
#
#   PART_<N>=<partition device>
#   MAPPER_<N>=<mapper device>    (only for luks-* specs)
#
# Progress, prompts, and errors all go to stderr so that
#   eval "$(./format.sh -p boot -p luks-ext4 /dev/vda)"
# captures only the variable assignments.
#
# With no -p, format.sh just clears partition signatures via wipefs
# (and runs the optional -e erase pass), leaving an unpartitioned
# drive behind. Note that without -e, file data on the drive is
# unreferenced but not actually erased.
#
# Sizes use sgdisk's `+SIZE` syntax (K/M/G/T mean KiB/MiB/GiB/TiB; sgdisk
# does not accept decimal units). A trailing "iB" is accepted as a
# synonym, so "512MiB" and "512M" are equivalent. Omit the size on the
# last -p to use remaining space.
#
# Requires: gptfdisk (sgdisk), cryptsetup, dosfstools, e2fsprogs,
# exfatprogs (the last three only as needed by the chosen specs).
# Run as root.
#
# See also: install.sh
#
set -e

usage() {
    echo "Usage: format.sh [-k] [-y] [-e <source>] [-K <keyfile>] [-p <spec>...] <device>"
    echo
    echo "Clear <device>'s partition signatures and (optionally) lay out"
    echo "new partitions / filesystems. With no -p, just clears signatures."
    echo "Pair with -e to leave a fully erased drive behind."
    echo
    echo "  -p <spec>     Partition spec, repeat once per partition. Specs:"
    echo "                  boot[:<size>]            ESP (fat32, default 512MiB)"
    echo "                  <fstype>[:<size>]        plain ext4/exfat/..."
    echo "                  luks-<fstype>[:<size>]   LUKS-wrapped <fstype>"
    echo "                Omit size on the last -p to use remaining space."
    echo "  -k            Leave LUKS volumes open after formatting."
    echo "  -y            Skip the confirmation prompt."
    echo "  -e <source>   Erase <device> with dd if=<source> first."
    echo "  -K <keyfile>  Read LUKS passphrase from <keyfile> (no TTY prompt)."
    echo "  -h            Show this help."
    echo
    echo "On success prints PART_<N>=... (and MAPPER_<N>=... for LUKS) to stdout."
    exit "${1:-0}"
}

error() { echo "ERROR: $1" >&2; exit 1; }

ending_digit() { case $1 in *[0-9]) true ;; *) false ;; esac; }
partition_name() {
    if ending_digit "$1"; then echo "$1p$2"; else echo "$1$2"; fi
}

specs=()
keep_open=0
auto_yes=0
erase=
key_file=
while getopts 'p:e:K:kyh' arg; do case "$arg" in
    p) specs+=("$OPTARG") ;;
    e) erase=$OPTARG ;;
    K) key_file=$OPTARG ;;
    k) keep_open=1 ;;
    y) auto_yes=1 ;;
    h) usage 0 ;;
    *) usage 1 ;;
esac done
shift $((OPTIND - 1))
target=$1

[ -z "$target" ] && usage 1
[ "$EUID" -eq 0 ] || error "run as root."
[ -n "$key_file" ] && [ ! -r "$key_file" ] && error "key file not readable: $key_file"

# Parse specs into parallel arrays. Validate that only the last spec may
# omit a size.
declare -a fstypes is_luks is_boot sizes
nspecs=${#specs[@]}
for i in "${!specs[@]}"; do
    spec=${specs[$i]}
    luks=0; boot=0
    case "$spec" in
        boot|boot:*)
            boot=1
            fstype="vfat"
            sz=${spec#boot}; sz=${sz#:}
            [ -z "$sz" ] && sz="512MiB"
            ;;
        luks-*)
            luks=1
            inner=${spec#luks-}
            case "$inner" in
                *:*) fstype=${inner%%:*}; sz=${inner#*:} ;;
                *)   fstype=$inner; sz="" ;;
            esac
            ;;
        *)
            case "$spec" in
                *:*) fstype=${spec%%:*}; sz=${spec#*:} ;;
                *)   fstype=$spec; sz="" ;;
            esac
            ;;
    esac

    [ -z "$sz" ] && [ "$i" -ne $((nspecs - 1)) ] && \
        error "only the last -p may omit a size: $spec"

    fstypes+=("$fstype")
    is_luks+=("$luks")
    is_boot+=("$boot")
    sizes+=("$sz")
done

# Confirmation prompt: last chance before we wipe.
{
    if [ ${#specs[@]} -gt 0 ]; then
        echo "About to partition $target:"
    else
        echo "About to clear partition signatures on $target."
    fi
    echo
    echo "Current:"
    lsblk "$target"
    if [ -n "$erase" ]; then
        echo
        echo "Will erase first with: dd if=$erase"
    fi
    if [ ${#specs[@]} -gt 0 ]; then
        echo "New:"
        p=0
        for i in "${!specs[@]}"; do
            p=$((p + 1))
            sz=${sizes[$i]:-rest}
            kind="${fstypes[$i]}"
            [ "${is_boot[$i]}" = 1 ] && kind="ESP (vfat)"
            [ "${is_luks[$i]}" = 1 ] && kind="luks+${fstypes[$i]}"
            printf "  %d. %-22s %s\n" "$p" "$kind" "$sz"
        done
        [ "$keep_open" = 1 ] && echo "LUKS volumes will be left open."
    fi
    echo
} >&2
if [ "$auto_yes" != 1 ]; then
    read -rp "Are you sure? [Y/n] " answer >&2
    case "$answer" in [yY][eE][sS]|[yY]) ;; *) echo "quitting." >&2; exit 0 ;; esac
fi

###############################################################################

# Unmount anything currently holding the device, then optionally erase
# the contents. wipefs strips filesystem / partition-table magic so the
# kernel and tools won't recognize stale layouts; it does NOT scrub
# bulk data; that's what -e is for.
umount "$target"?* 2>/dev/null || true
[ -n "$erase" ] && dd if="$erase" of="$target" status=progress >&2

wipefs -a "$target" >&2

# No -p: signatures cleared (and -e applied if given). Done.
[ ${#specs[@]} -eq 0 ] && exit 0

# Build sgdisk command. -n N:0:end uses the next aligned start; end is
# +SIZE for sized parts and 0 (rest of disk) for an omitted size.
# sgdisk's units are binary K/M/G/T; strip an explicit "iB" suffix so
# "512MiB" works the same as "512M".
sgdisk_args=()
for i in "${!specs[@]}"; do
    n=$((i + 1))
    sz=${sizes[$i]%iB}
    end=$([ -z "$sz" ] && echo "0" || echo "+$sz")
    if [ "${is_boot[$i]}" = 1 ]; then
        type_code="ef00"
    elif [ "${is_luks[$i]}" = 1 ]; then
        type_code="8309"
    else
        type_code="8300"
    fi
    sgdisk_args+=("-n" "$n:0:$end" "-t" "$n:$type_code")
done
sgdisk -Z "${sgdisk_args[@]}" "$target" >&2

# sgdisk asks the kernel to re-read the partition table on exit; wait
# for udev to finish creating the new device nodes before formatting.
udevadm settle

for i in "${!specs[@]}"; do
    n=$((i + 1))
    part=$(partition_name "$target" "$n")
    fstype=${fstypes[$i]}

    if [ "${is_luks[$i]}" = 1 ]; then
        mapper="cryptroot-$n"
        # With -K: feed the key file to cryptsetup so neither luksFormat
        # (which otherwise prompts for passphrase + verify + asks for a
        # YES confirmation) nor luksOpen blocks on a TTY. -q skips the
        # YES prompt; --key-file= bypasses both passphrase prompts.
        if [ -n "$key_file" ]; then
            cryptsetup -q luksFormat "$part" --key-file="$key_file" >&2
            cryptsetup luksOpen "$part" "$mapper" --key-file="$key_file" >&2
        else
            cryptsetup luksFormat "$part" >&2
            cryptsetup luksOpen "$part" "$mapper" >&2
        fi
        device="/dev/mapper/$mapper"
    else
        device=$part
    fi

    case "$fstype" in
        vfat)  mkfs.vfat -F32 "$device" >&2 ;;
        ext4)  mkfs.ext4 -F "$device"   >&2 ;;
        exfat) mkfs.exfat   "$device"   >&2 ;;
        *)     error "unsupported fstype: $fstype" ;;
    esac

    echo "PART_$n=$part"
    if [ "${is_luks[$i]}" = 1 ]; then
        if [ "$keep_open" = 1 ]; then
            echo "MAPPER_$n=$device"
        else
            cryptsetup luksClose "cryptroot-$n" >&2
        fi
    fi
done
