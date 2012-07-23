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
	#
	# To ensure an up-to-date zpool.cache, we create a dummy pool then destroy it.
	# This operation has the side effect of updating zpool.cache.
	# This is needed for the following reason:
	#
	# We need to do this because, otherwise, pools that can be imported just fine
	# with the most-up-to-date zpool.cache, don't import properly when the file is
	# out-of-date or absent.  This is especially true in the case of initramfs.
	#
	# An example of the above:
	#
	# - Boot fails because, for some reason, the root pool could not be imported.
	# - User breaks into initramfs, then imports the pool -f, then continues boot.
	# - At this point, only the zpool.cache file in the initramfs is updated,
	#   but not the one in /etc/zfs proper.
	# - Boot continues normally
	# - User redoes initramfs to update the zpool.cache in it.  This zpool.cache
	#   is out of date because it was never updated.
	# - User reboots
	# - Boot fails yet again
	#
	# With this hack, we can ensure that, no matter what operations the user has
	# performed without updating zpool.cache, the most-up-to-date copy of the
	# zpool.cache is generated.  Users having to manually import their pools
	# during initramfs only need to regenerate the initramfs, and that solves
	# their problem completely and for good (or, more accurately, until they
	# change their pool configuration).
	#
	tmpf=`mktemp` ; tmpp=lk23jlkjflsa9f209jfsdlkfjlvfsaf
	dd if=/dev/zero of="$tmpf" bs=1048576 count=64 2>/dev/null
	@sbindir@/zpool create -m none "$tmpp" "$tmpf"
	@sbindir@/zpool destroy "$tmpp"
	rm -f "$tmpf"
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
	if grep -q 'hookdir.*shutdown' @dracutdir@/dracut-functions ; then
		# aha, dracut support for shutdown hooks is available!
	        # we add the export twice
	        # once before crypt for ZFS pools on top of luks,
	        # and once after crypt, for luks on top of ZFS volumes
		inst_hook shutdown 20 "$moddir/export-zfs.sh"
		inst_hook shutdown 40 "$moddir/export-zfs.sh"
	fi
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
