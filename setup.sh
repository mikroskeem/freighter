#!/bin/sh
set -ex

#ip link set eth0 up
#udhcpc eth0
#apk add curl
#curl https://mikroskeem.eu/alpine/setup.sh
setup-apkrepos -1
apk update


DISK=/dev/disk/by-id/virtio-13377331

apk add zfs zfs-udev sgdisk eudev e2fsprogs rsync
setup-udev
modprobe ext4
modprobe zfs

# needed for zvols
udevadm control --reload
udevadm trigger


sgdisk --force --zap-all "${DISK}"
sgdisk -a1 -n2:34:2047 -t2:EF02 "${DISK}"
#if is_efi; then
#	sgdisk -n3:1M:+512M -t3:EF00 "${DISK}"
#fi
sgdisk -n1:0:0 -t1:BF01 "${DISK}"

partprobe
sleep 5 # HACK
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
	-R /mnt rpool "${DISK}-part1"

zfs create -o mountpoint=none rpool/root
zfs create -o mountpoint=legacy rpool/root/alpine

# HACK: install alpine on ext4 first, installer complains otherwise
zfs create -V 2G rpool/root/alpine-ext4
sleep 2 # HACK
mkfs.ext4 /dev/zvol/rpool/root/alpine-ext4
mount /dev/zvol/rpool/root/alpine-ext4 /mnt

# NOTE: do not create /mnt/boot
setup-disk -v /mnt

# copy files over
mkdir -p /mnt2
mount -t zfs rpool/root/alpine /mnt2
rsync -ax /mnt/ /mnt2

# nuke zvol and mount zfs dataset at right place
umount /mnt
zfs destroy rpool/root/alpine-ext4
mount --bind /mnt2 /mnt

# post-copy setup
chroot /mnt /bin/sh -ec '
setup-udev -n
apk add zfs zfs-udev

# rewrite mkinitfs
. /etc/mkinitfs/mkinitfs.conf; echo features=\"${features} zfs\" > /etc/mkinitfs/mkinitfs.conf

# setup boot stuff
rc-update add zfs-import sysinit
rc-update add zfs-mount sysinit

# todo: regenerate initramfs
'


#curl -o answers.txt https://mikroskeem.eu/alpine/answers.txt
#setup-alpine -q -e -f ./answers.txt
