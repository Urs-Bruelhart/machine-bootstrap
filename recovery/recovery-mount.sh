#!/bin/bash
set -e

self_path=$(dirname "$(readlink -e "$0")")
force=false
what=all
passphrase=""

if test "$1" != "--yes"; then
    cat <<EOF
Usage:
    $0 --yes --only-raid-crypt [--luks-from-stdin]
    $0 --yes [--without-raid-crypt] [--force]
EOF
    exit 1
fi
shift
if test "$1" = "--only-raid-crypt"; then what=until_crypt; shift; fi
if test "$1" = "--luks-from-stdin"; then passphrase=$(cat -); shift; fi
if test "$1" = "--without-raid-crypt"; then what=after_crypt; shift; fi
if test "$1" = "--force"; then force=true; shift; fi

. "$self_path/bootstrap-library.sh"

if which cloud-init > /dev/null; then
    printf "waiting for cloud-init finish..."
    cloud-init status --wait
fi

if test "$what" != "after_crypt"; then
    zfs_packages="$(get_zfs_packages)"
    echo "update sources, install $zfs_packages"
    DEBIAN_FRONTEND=noninteractive apt-get update --yes
    DEBIAN_FRONTEND=noninteractive apt-get install --yes $zfs_packages
    for i in /dev/md1*; do mdadm --manage --stop $i; done
    activate_raid
    create_crypttab
    activate_crypt "$passphrase"
fi
if test "$what" = "until_crypt"; then exit 0; fi

mount_root /mnt $force
mount_boot /mnt $force
mount_efi /mnt
mount_data /mnt $force
mount_bind_mounts /mnt

echo "chroot to system, use exit to exit"
chroot /mnt /bin/bash --login
echo "exited from chroot, to chroot again type 'chroot /mnt /bin/bash --login'"
echo "before reboot, use 'recovery-unmount.sh --yes' to unmount disks, then reboot"
