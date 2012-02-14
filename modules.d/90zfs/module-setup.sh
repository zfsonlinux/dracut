#!/bin/sh

check() {
	# We depend on udev-rules being loaded
	[ "$1" = "-d" ] && return 0

	# Verify the zfs tool chain
	which zpool >/dev/null 2>&1 || return 1
	which zfs >/dev/null 2>&1 || return 1

	return 0
}

depends() {
	echo udev-rules
	return 0
}

installkernel() {
	instmods zfs
	instmods zcommon
	instmods znvpair
	instmods zavl
	instmods zunicode
	instmods spl
	instmods zlib_deflate
	instmods zlib_inflate
}

install() {
	inst_rules 90-zfs.rules
	inst_rules 60-zpool.rules
	inst_rules 60-zvol.rules
	inst /etc/zfs/zdev.conf
	inst /etc/zfs/zpool.cache
	inst_binary zfs
	inst_binary zpool
	inst_binary zpool_layout
	dracut_install /lib/udev/zpool_id
	dracut_install /lib/udev/zvol_id
	dracut_install mount.zfs
	dracut_install hostid
	inst_hook cmdline 95 "$moddir/parse-zfs.sh"
	inst_hook mount 98 "$moddir/mount-zfs.sh"

	# Synchronize initramfs and system hostid
	TMP=`mktemp`
	AA=`hostid | cut -b 1,2`
	BB=`hostid | cut -b 3,4`
	CC=`hostid | cut -b 5,6`
	DD=`hostid | cut -b 7,8`
	printf "\x$DD\x$CC\x$BB\x$AA" >$TMP
	inst_simple "$TMP" /etc/hostid
	rm "$TMP"
}
