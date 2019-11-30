#!/bin/bash
set -eo pipefail
set -x

self_path=$(dirname "$(readlink -e "$0")")


usage() {
    cat <<EOF
Usage: cat diskkey | $0 hostname firstuser disklist --yes [optional parameter]

optional parameter:
[--root-lvm-vol-size <volsizemb>] [--frankenstein] [--distribution <name>] [--restore-from-backup]

--root-lvm-vol-size <volsizemb>
    if lvm is used, define the capacity of the lvm root volume, defaults to 20480 (20gb)
--frankenstein
    backport and patch zfs-linux with no-d-revalidate.patch
--distribution <name>
    select a different distribution (default=$distribution)
--restore-from-backup
    partition and format system, restore from backup, adapt to new storage

"http_proxy" environment variable:
    the environment variable "http_proxy" will be used if set
    and must follow the format "http://1.2.3.4:1234"
EOF
    exit 1
}

warn_rename() { # targetfile
    local targetfile=$1
    if test -e "$targetfile"; then
        echo "WARNING: target $targetfile exists, renaming to ${targetfile}.old"
        mv "$targetfile" "${targetfile}.old"
    fi
}


# const
custom_archive=/usr/local/lib/bootstrap-custom-archive
custom_sources_list=/etc/apt/sources.list.d/local-bootstrap-custom.list
# defaults
option_frankenstein=false
option_restore_backup=false
distribution="bionic"
root_lvm_vol_size="20480"

# parse args
if test "$4" != "--yes"; then usage; fi
hostname=$1
if test "$hostname" = "${hostname%%.*}"; then
    hostname="${hostname}.local"
fi
firstuser=$2
disklist=$3
shift 4
fulldisklist=$(for i in $disklist; do echo "/dev/disk/by-id/${i} "; done)
diskcount=$(echo "$disklist" | wc -w)
if test "$diskcount" -gt "2"; then
    echo "ERROR: script only works with one or two disks, but disks=$diskcount"
    exit 1
fi
diskpassword=$(cat -)
if test "$diskpassword" = ""; then
    echo "ERROR: script needs diskpassword from stdin, abort"
    exit 1
fi
if test "$1" = "--root-lvm-vol-size"; then root_lvm_vol_size="$2"; shift; fi
if test "$1" = "--frankenstein"; then option_frankenstein=true; shift; fi
if test "$1" = "--distribution"; then distribution=$2; shift 2; fi
if test "$1" = "--restore-from-backup"; then option_restore_backup=true; shift; fi

# if http_proxy is set, reexport for sub-processes
if test "$http_proxy" != ""; then export http_proxy; fi

# include library
. "$self_path/bootstrap-library.sh"

# show important settings to user
cat << EOF
Configuration:
hostname: $hostname, firstuser: $firstuser
fulldisklist: $(for i in $fulldisklist; do echo -n " $i"; done)
http_proxy: $http_proxy
distribution: $distribution
option_frankenstein: $option_frankenstein
option_restore_backup: $option_restore_backup
root_lvm_vol_size: $root_lvm_vol_size
EOF

# ## main
cd /tmp
if which cloud-init > /dev/null; then
    echo -n "waiting for cloud-init finish..."
    cloud-init status --wait
fi

echo "set target hostname in recovery system"
setup_hostname "$hostname"

# compile custom zfs-linux if requested
if $option_frankenstein; then
    if test ! -e /tmp/zfs/build-custom-zfs.sh -o ! -e /tmp/zfs/no-dops-snapdirs.patch; then
        echo "error: could not find needed files for frankenstein zfs-linux build, continue without custom build"
    else
        echo "build-custom-zfs"
        chmod +x /tmp/zfs/build-custom-zfs.sh
        /tmp/zfs/build-custom-zfs.sh /tmp/zfs/basedir --source eoan --dest bionic
        if test -e $custom_archive; then rm -rf $custom_archive; fi
        mkdir -p $custom_archive
        mv -t $custom_archive /tmp/zfs/basedir/build/buildresult/*
        rm -rf /tmp/zfs/basedir
        cat > $custom_sources_list << EOF
deb [ trusted=yes ] file:$custom_archive ./
EOF
        DEBIAN_FRONTEND=noninteractive apt-get update --yes
    fi
fi

echo "install needed packages"
packages="$(get_default_packages)"
packages="$packages $(get_zfs_packages)"
packages="$packages lvm2"
DEBIAN_FRONTEND=noninteractive apt-get install --yes $packages

echo "generate new zfs hostid (/etc/hostid) in active system"
if test -e /etc/hostid; then rm /etc/hostid; fi
zgenhostid

# create & mount target filesystems
create_and_mount_root /mnt $diskpassword $root_lvm_vol_size
create_boot
create_data $diskpassword
create_swap $diskpassword
create_homedir home $firstuser
mount_boot /mnt
mount_efi /mnt
mount_data /mnt

if $option_restore_backup; then
    echo "call bootstrap-1-restore"
    chmod +x /tmp/bootstrap-1-restore.sh
    /tmp/bootstrap-1-restore.sh "$hostname" "$firstuser" --yes && err=$? || err=$?
    if test "$err" != "0"; then echo "Backup - Restore Error $err"; exit $err; fi
else
    echo "install minimal base $distribution system"
    debootstrap --verbose "$distribution" /mnt
fi
create_root_finished

# chroot preperations
echo "copy/overwrite hostid (/etc/hostid)"
cp -a /etc/hostid /mnt/etc/hostid

echo "copy authorized_keys"
install -m "0700" -d /mnt/root/.ssh
warn_rename /mnt/root/.ssh/authorized_keys
cp /tmp/authorized_keys /mnt/root/.ssh/authorized_keys
chmod "0600" /mnt/root/.ssh/authorized_keys

echo "copy network config"
warn_rename /mnt/etc/netplan/80-lan.yaml
cp -a /tmp/netplan.yaml /mnt/etc/netplan/80-lan.yaml

if $option_frankenstein; then
    echo "copy custom archive files"
    if test -e "/mnt$custom_archive"; then
        if $option_restore_backup; then
            echo "WARNING: --restore-from-backup: not deleting existing target dir $custom_archive"
        else
            echo "WARNING: removing existing $custom_archive"
            rm -rf "/mnt$custom_archive"
        fi
    fi
    echo "insert distribution into /etc/pbuilderrc"
    echo "DISTRIBUTION=$distribution" >> /mnt/etc/pbuilderrc
    mkdir -p "/mnt$custom_archive"
    cp -t "/mnt$custom_archive" $custom_archive/*
    cat > "/mnt$custom_sources_list" << EOF
deb [ trusted=yes ] file:$custom_archive ./
EOF
    # remove archive from ramdisk, it is already installed in running system and copied to target
    rm -r $custom_archive
    rm $custom_sources_list
fi

echo "copy additional bootstrap files"
mkdir -p /mnt/usr/lib/dracut/modules.d/46sshd
cp -a -t /mnt/usr/lib/dracut/modules.d/46sshd /tmp/initrd/*
mkdir -p /mnt/etc/recovery/zfs
cp -a -t /mnt/etc/recovery /tmp/recovery/*
cp -a -t /mnt/etc/recovery/zfs /tmp/zfs/*
cp /tmp/bootstrap-library.sh /mnt/etc/recovery
cp /tmp/recovery_hostkeys /mnt/etc/recovery
chmod 0600 /mnt/etc/recovery/recovery_hostkeys
cp /tmp/bootstrap-library.sh /mnt/tmp
cp /tmp/bootstrap-2-chroot-install.sh /mnt/tmp
chmod +x /mnt/tmp/bootstrap-2-chroot-install.sh

mount_bind_mounts "/mnt"

bootstrap2_postfix=""
if test "$option_restore_backup" = "true"; then
    bootstrap2_postfix="--restore-from-backup"
fi
echo "call bootstrap-2-chroot $bootstrap2_postfix in chroot"
chroot /mnt /tmp/bootstrap-2-chroot-install.sh \
    "$hostname" "$firstuser" --yes $bootstrap2_postfix
echo "back in bootstrap-1-install"

if test "$option_restore_backup" = "true"; then
    echo "call bootstrap-2-chroot-restore"
    cp -a /tmp/bootstrap-2-chroot-restore.sh /mnt/tmp
    chmod +x /mnt/tmp/bootstrap-2-chroot-restore.sh
    chroot /mnt /tmp/bootstrap-2-chroot-restore.sh \
        "$hostname" "$firstuser" --yes && err=$? || err=$?
    echo "back in bootstrap-1-install"
    if test "$err" != "0"; then echo "Backup - Restore Error $err"; exit $err; fi
fi

echo "copy initrd and system ssh host keys"
mkdir -p /tmp/ssh_hostkeys
for i in initrd_ssh_host_ed25519_key.pub ssh_host_ed25519_key.pub ssh_host_rsa_key.pub; do
    cp /mnt/etc/ssh/$i /tmp/ssh_hostkeys
done

echo "swap off"; swapoff -a || true
unmount_bind_mounts /mnt
unmount_data /mnt
unmount_efi /mnt
unmount_boot /mnt
sleep 1
unmount_root /mnt
