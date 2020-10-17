#!/bin/sh
set -ex

#ip link set eth0 up
#udhcpc eth0
#apk add curl
#curl https://mikroskeem.eu/alpine/setup.sh
setup-apkrepos -1
apk update


DISK=/dev/disk/by-id/virtio-13377331
mnt=/mnt

apk add zfs zfs-udev sgdisk eudev \
	grub grub-bios grub-efi
setup-udev
modprobe ext4
modprobe zfs

# needed for /dev/disk/*
udevadm control --reload
udevadm trigger
sleep 1

sgdisk --zap-all "${DISK}"
sgdisk -a1 -n2:34:2047 -t2:EF02 "${DISK}"
#if is_efi; then
#	sgdisk -n3:1M:+512M -t3:EF00 "${DISK}"
#fi
sgdisk -n1:0:0 -t1:BF01 "${DISK}"

partprobe
sleep 5 # HACK
# NOTE: encryption is incompatible with grub. force separate boot partition when encryption is desired
#-O encryption=aes-256-gcm -O keylocation=prompt -O keyformat=passphrase \
zpool create \
	-f \
	-O mountpoint=none \
	-O atime=off \
	-O compression=lz4 \
	-O normalization=formD \
	-O xattr=sa \
	-O acltype=posixacl \
	-O canmount=off \
	-o ashift=12 \
	-R "${mnt}" rpool "${DISK}-part1"

zfs create -o mountpoint=none rpool/root
zfs create -o mountpoint=legacy rpool/root/alpine
mount -t zfs rpool/root/alpine "${mnt}"

export ZPOOL_VDEV_NAME_PATH=1 # needed for grub

# Install bootloader. Must be done before installing system to make grub package trigger work
#if is_efi; then
#else
#grub-install --target=x86_64-efi --bootloader-id=alpine \
#	--efi-directory="${mnt}/boot" --boot-directory="${mnt}/boot" \
#	--no-nvram --portable
grub-install --boot-directory="${mnt}/boot" --target=i386-pc "${DISK}"
#fi

install -o root -g root -D /dev/stdin "${mnt}"/etc/default/grub <<- EOF
GRUB_TIMEOUT=2
GRUB_DISABLE_SUBMENU=y
GRUB_DISABLE_RECOVERY=true
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"
EOF

# Install alpine manually using apk
mkdir -p "${mnt}"/etc/apk/keys/
cp /etc/apk/keys/* "${mnt}"/etc/apk/keys/
cp /etc/apk/repositories "${mnt}"/etc/apk/

apk add --root "${mnt}" \
	--initdb --progress --update-cache --clean-protected \
	acct linux-lts alpine-base zfs zfs-udev eudev e2fsprogs grub grub-bios grub-efi \
	chrony openssh-server openssh-client openssl bash

# --quiet \

# post-copy setup
_hn=alpine

# TODO: options: cdn (default) or fastest
rm "${mnt}"/etc/apk/repositories
ROOT="${mnt}" setup-apkrepos -1

ROOT="${mnt}" setup-interfaces -p "${mnt}" -a
#ROOT="${mnt}" setup-keymap us us
ROOT="${mnt}" setup-hostname -n "${_hn}"
ROOT="${mnt}" setup-timezone -z UTC
ROOT="${mnt}" setup-interfaces -i <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
	hostname ${_hn}
EOF

cat > "${mnt}/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF

for m in dev proc sys; do
	mount --bind "/${m}" "${mnt}/${m}"
done

chroot "${mnt}" /bin/sh -ec '
# rewrite mkinitfs config
{
	. /etc/mkinitfs/mkinitfs.conf
	echo features=\"${features} zfs\" > /etc/mkinitfs/mkinitfs.conf
}

# setup boot stuff
setup-udev -n
rc-update add zfs-import sysinit
rc-update add zfs-mount sysinit
rc-update add zfs-zed sysinit
rc-update add acpid default
rc-update add crond default
rc-update add sshd default
rc-update add chronyd default
rc-update add networking boot
rc-update add urandom boot

# set up hostid
if ! [ -f /etc/hostid ]; then
	zgenhostid "$(openssl rand -hex 4)"
fi

# regenerate initramfs
for d in /lib/modules/*; do
	kver="$(basename -- "${d}")"
	mkinitfs "${kver}"
done

export ZPOOL_VDEV_NAME_PATH=1
# generate grub config
grub-mkconfig -o /boot/grub/grub.cfg

# apk grub trigger failed before; ensure that error state will be gone
# TODO: does not pick up the env var
#apk fix
'

# NOTE: root password is not set.

# TODO: recursive unmount?
#umount -R /mnt
for m in dev proc sys; do
	umount "${mnt}/${m}"
done
zpool export rpool
