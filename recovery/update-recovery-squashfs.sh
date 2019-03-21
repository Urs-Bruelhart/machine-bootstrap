#!/bin/sh
set -e
# set -x

usage() {
    
    cat << EOF
Usage:  $0 --host [<hostname>]
        $0 --custom <squashfsoutputfile> <hostname> <hostid>|-  
                    <netplan_file> <hostkeys_file> <authorized_keys_file>
                    <scriptdir> <archivedir>|- <autologin(yes|no)> [<http_proxy>]
defaults:
  squashfsoutputfile:   /boot/casper/recovery.squashfs
  hostname:             if not set from commandline, get from hostname -f
  hostid:               if exists from /etc/hostid else "-"
  netplan_file:         if exists from /etc/recovery/netplan.yml or from /etc/netplan/*
  hostkeys_file:        from /etc/recovery/recovery_hostkeys
  authorized_keys_file: from /root/.ssh/authorized_keys
  scriptdir:            from  /etc/recovery (to recovery:/sbin/)
  archivedir:           if exists "/usr/local/lib/custom-apt-archive" else "-"
                        expects local apt-archive with "Release" and "Packages" files
  autologin:            "yes" if exists /etc/recovery/feature.autologin else "no"
  http_proxy:           from default env

EOF
    exit 1
}


generate_recovery_squashfs() {
    local basedir cfgdir destfile hostname hostid netplan_data hostkeys_data
    local authorized_keys_data scriptdir archivedir autologin http_proxy
    destfile=$1; hostname=$2; hostid=$3; netplan_data="$4"; hostkeys_data="$5";
    authorized_keys_data="$6"; scriptdir=$7; archivedir=$8; autologin=$9;
    http_proxy="${10}"
    basedir=/tmp/mk.squashfs
    cfgdir="$basedir/etc/cloud/cloud.cfg.d"

    echo "create recovery.squashfs"
    if test -d $basedir; then rm -rf $basedir; fi
    mkdir -p "$cfgdir"

    echo "write meta-data.cfg"
    printf "instance-id: %s\nlocal-hostname: %s\n" $hostname $hostname > "$cfgdir/meta-data.cfg"

    echo "write netplan as network-config.cfg"
    echo "$netplan_data" > "$cfgdir/network-config.cfg"

    ci_http_proxy=""
    no_ssh_genkeytypes=""
    if test "$http_proxy" != ""; then
        ci_http_proxy="http_proxy: \"$http_proxy\""
    fi
    if test "$hostkeys_data" != ""; then
        no_ssh_genkeytypes="ssh_genkeytypes: []"
    fi

    packages="cryptsetup gdisk mdadm grub-pc grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed efibootmgr squashfs-tools curl ca-certificates bzip2 tmux zfs-dkms zfsutils-linux haveged debootstrap libc-bin"
    
    cat > "$cfgdir/user-data.cfg" <<EOF
#cloud-config
# XXX keep the "#cloud-config" line first and unchanged

preserve_hostname: false
fqdn: $hostname

apt:
  sources_list: |
      deb \$MIRROR \$RELEASE main restricted universe multiverse
      deb \$MIRROR \$RELEASE-updates main restricted universe multiverse
      deb \$SECURITY \$RELEASE-security main restricted universe multiverse
  $ci_http_proxy  

package_upgrade: false
packages:
$(for p in $packages; do printf "  - %s\n" "$p"; done)

disable_root: false
ssh_pwauth: false
ssh_deletekeys: true
$no_ssh_genkeytypes

users:
  - name: root
    lock_passwd: true
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
$(printf "%s" "$authorized_keys_data" | sed -e 's/^/      - /')

ssh_authorized_keys:
$(printf "%s" "$authorized_keys_data" | sed -e 's/^/  - /')

EOF
    if test "$hostkeys_data" != ""; then
        echo "write recovery_hostkeys to user-data.cfg"
        printf "%s\n\n" "$hostkeys_data" >> "$cfgdir/user-data.cfg"
    fi
    if test "$autologin" = "yes"; then
        echo "modify tty1 for autologin"
        mkdir -p "$basedir/etc/systemd/system/getty@tty1.service.d"
        cat > "$basedir/etc/systemd/system/getty@tty1.service.d/override.conf" <<"EOF"
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --noclear %I $TERM
EOF
    fi
    
    if test "$hostid" != "-"; then
        echo "add /etc/hostid"
        printf "%s" "$hostid" > $basedir/etc/hostid
    fi
    
    echo "include helper scripts in squashfs"
    mkdir -p $basedir/sbin
    cp -a $scriptdir/*.sh $basedir/sbin/
    
    if test "$archivedir" != ""; then
        echo "include custom archive in squashfs"
        mkdir -p "$basedir$archivedir"
        cp -t "$basedir$archivedir" $archivedir/*
        mkdir -p $basedir/etc/apt/sources.list.d
        cat > $basedir/etc/apt/sources.list.d/local-apt-archive.list << EOF
deb [ trusted=yes ] file:$archivedir ./
EOF
    fi

    echo "create squashfs"
    cd $basedir
    mksquashfs . "$destfile"
    cd /
}

if test "$1" != "--host" -a "$1" != "--custom"; then usage; fi

if test "$1" = "--host"; then
    $0 --custom \
    /boot/casper/recovery.squashfs \
    $(test "$2" != "" && echo "$2" || echo $(hostname -f)) \
    "$(test -e /etc/hostid && echo "/etc/hostid" || printf '%s' '-')" \
    "$(test -e /etc/recovery/netplan.yml && echo '/etc/recovery/netplan.yml' || echo '/etc/netplan/*')" \
    /etc/recovery/recovery_hostkeys \
    /root/.ssh/authorized_keys \
    /etc/recovery \
    $(test -e /usr/local/lib/custom-apt-archive && echo "/usr/local/lib/custom-apt-archive" || printf '%s' '-') \
    $(test -e /etc/recovery/feature.autologin && echo "yes" || echo "no") \
    $http_proxy
else
    shift
    if test "$9" = ""; then usage; fi
    destfile=$1
    hostname=$2
    hostid_file=$3
    netplan_file=$4
    hostkeys_file=$5
    authorized_keys_file=$6
    scriptdir=$7
    archivedir=$8
    autologin=$9
    http_proxy="${10}"
    for i in $netplan_file $hostkeys_file $authorized_keys_file; do
        if test ! -e "$i"; then
            echo "Error: file $i not found"
            usage
        fi
    done
    if test "$hostid_file" = "-"; then
        hostid_data="-"
    elif test -e "$hostid_file"; then 
        hostid_data=$(cat "$hostid_file")
    else
        echo "Error: file $hostid_file not found"
        usage
    fi
    if test "$archivedir" != "-"; -a test ! -d $archivedir; then
        echo "Error: directory $archivedir not found"
        usage
    fi
    netplan_data=$(cat $netplan_file)
    hostkeys_data=$(cat "$hostkeys_file")
    authorized_keys_data=$(cat "$authorized_keys_file")
    if test -e "$destfile"; then
        echo "Warning: destination file already exists, renaming to ${destfile}.old"
        mv "$destfile" "${destfile}.old"
    fi
    generate_recovery_squashfs "$destfile" "$hostname" "$hostid_data" "$netplan_data" \
    "$hostkeys_data" "$authorized_keys_data" "$scriptdir" "$archivedir" "$autologin" "$http_proxy"
fi
