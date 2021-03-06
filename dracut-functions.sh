#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh
#
# functions used by dracut and other tools.
#
# Copyright 2005-2009 Red Hat, Inc.  All rights reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
export LC_MESSAGES=C

if [[ $DRACUT_KERNEL_LAZY ]] && ! [[ $DRACUT_KERNEL_LAZY_HASHDIR ]]; then
    if ! [[ -d "$initdir/.kernelmodseen" ]]; then
        mkdir -p "$initdir/.kernelmodseen"
    fi
    DRACUT_KERNEL_LAZY_HASHDIR="$initdir/.kernelmodseen"
fi

if [[ $initdir ]] && ! [[ -d $initdir ]]; then
    mkdir -p "$initdir"
fi

# Generic substring function.  If $2 is in $1, return 0.
strstr() { [[ $1 = *$2* ]]; }

# find a binary.  If we were not passed the full path directly,
# search in the usual places to find the binary.
find_binary() {
    if [[ -z ${1##/*} ]]; then
        if [[ -x $1 ]] || { [[ "$1" == *.so* ]] && ldd "$1" &>/dev/null; };  then
            printf "%s\n" "$1"
            return 0
        fi
    fi

    type -P "${1##*/}"
}

if ! [[ $dracutbasedir ]]; then
    dracutbasedir=${BASH_SOURCE[0]%/*}
    [[ $dracutbasedir = "dracut-functions" ]] && dracutbasedir="."
    [[ $dracutbasedir ]] || dracutbasedir="."
    dracutbasedir="$(readlink -f $dracutbasedir)"
fi

if ! [[ $DRACUT_INSTALL ]]; then
    DRACUT_INSTALL=$(find_binary dracut-install)
fi

if ! [[ $DRACUT_INSTALL ]] && [[ -x $dracutbasedir/dracut-install ]]; then
    DRACUT_INSTALL=$dracutbasedir/dracut-install
fi

# Detect lib paths
if ! [[ $libdirs ]] ; then
    if [[ "$(ldd /bin/sh)" == */lib64/* ]] &>/dev/null \
        && [[ -d /lib64 ]]; then
        libdirs+=" /lib64"
        [[ -d /usr/lib64 ]] && libdirs+=" /usr/lib64"
    else
        libdirs+=" /lib"
        [[ -d /usr/lib ]] && libdirs+=" /usr/lib"
    fi
    export libdirs
fi

if ! [[ $kernel ]]; then
    kernel=$(uname -r)
    export kernel
fi

srcmods="/lib/modules/$kernel/"
[[ $drivers_dir ]] && {
    if vercmp "$(modprobe --version | cut -d' ' -f3)" lt 3.7; then
        dfatal 'To use --kmoddir option module-init-tools >= 3.7 is required.'
        exit 1
    fi
    srcmods="$drivers_dir"
}
export srcmods

if ! type dinfo >/dev/null 2>&1; then
    . "$dracutbasedir/dracut-logger.sh"
    dlog_init
fi

if ! [[ $initdir ]]; then
    dfatal "initdir not set"
    exit 1
fi

# export standard hookdirs
[[ $hookdirs ]] || {
    hookdirs="cmdline pre-udev pre-trigger netroot "
    hookdirs+="initqueue initqueue/settled initqueue/online initqueue/finished initqueue/timeout "
    hookdirs+="pre-mount pre-pivot cleanup mount "
    hookdirs+="emergency shutdown-emergency pre-shutdown shutdown "
    export hookdirs
}

dracut_need_initqueue() {
    >"$initdir/lib/dracut/need-initqueue"
}

dracut_module_included() {
    [[ "$mods_to_load $modules_loaded" == *$@* ]]
}

# Create all subdirectories for given path without creating the last element.
# $1 = path
mksubdirs() {
    [[ -e ${1%/*} ]] || mkdir -m 0755 -p -- "${1%/*}"
}

# Version comparision function.  Assumes Linux style version scheme.
# $1 = version a
# $2 = comparision op (gt, ge, eq, le, lt, ne)
# $3 = version b
vercmp() {
    local _n1=${1//./ } _op=$2 _n2=${3//./ } _i _res

    for ((_i=0; ; _i++))
    do
        if [[ ! ${_n1[_i]}${_n2[_i]} ]]; then _res=0
        elif ((${_n1[_i]:-0} > ${_n2[_i]:-0})); then _res=1
        elif ((${_n1[_i]:-0} < ${_n2[_i]:-0})); then _res=2
        else continue
        fi
        break
    done

    case $_op in
        gt) ((_res == 1));;
        ge) ((_res != 2));;
        eq) ((_res == 0));;
        le) ((_res != 1));;
        lt) ((_res == 2));;
        ne) ((_res != 0));;
    esac
}

# is_func <command>
# Check whether $1 is a function.
is_func() {
    [[ "$(type -t "$1")" = "function" ]]
}

# Function prints global variables in format name=value line by line.
# $@ = list of global variables' name
print_vars() {
    local _var _value

    for _var in "$@"
    do
        eval printf -v _value "%s" "\$$_var"
        [[ ${_value} ]] && printf '%s="%s"\n' "$_var" "$_value"
    done
}

# normalize_path <path>
# Prints the normalized path, where it removes any duplicated
# and trailing slashes.
# Example:
# $ normalize_path ///test/test//
# /test/test
normalize_path() {
    shopt -q -s extglob
    set -- "${1//+(\/)//}"
    shopt -q -u extglob
    echo "${1%/}"
}

# convert_abs_rel <from> <to>
# Prints the relative path, when creating a symlink to <to> from <from>.
# Example:
# $ convert_abs_rel /usr/bin/test /bin/test-2
# ../../bin/test-2
# $ ln -s $(convert_abs_rel /usr/bin/test /bin/test-2) /usr/bin/test
convert_abs_rel() {
    local __current __absolute __abssize __cursize __newpath
    local -i __i __level

    set -- "$(normalize_path "$1")" "$(normalize_path "$2")"

    # corner case #1 - self looping link
    [[ "$1" == "$2" ]] && { echo "${1##*/}"; return; }

    # corner case #2 - own dir link
    [[ "${1%/*}" == "$2" ]] && { echo "."; return; }

    IFS="/" __current=($1)
    IFS="/" __absolute=($2)

    __abssize=${#__absolute[@]}
    __cursize=${#__current[@]}

    while [[ "${__absolute[__level]}" == "${__current[__level]}" ]]
    do
        (( __level++ ))
        if (( __level > __abssize || __level > __cursize ))
        then
            break
        fi
    done

    for ((__i = __level; __i < __cursize-1; __i++))
    do
        if ((__i > __level))
        then
            __newpath=$__newpath"/"
        fi
        __newpath=$__newpath".."
    done

    for ((__i = __level; __i < __abssize; __i++))
    do
        if [[ -n $__newpath ]]
        then
            __newpath=$__newpath"/"
        fi
        __newpath=$__newpath${__absolute[__i]}
    done

    echo "$__newpath"
}

if [[ "$(ln --help)" == *--relative* ]]; then
    ln_r() {
        ln -sfnr "${initdir}/$1" "${initdir}/$2"
    }
else
    ln_r() {
        local _source=$1
        local _dest=$2
        [[ -d "${_dest%/*}" ]] && _dest=$(readlink -f "${_dest%/*}")/${_dest##*/}
        ln -sfn -- "$(convert_abs_rel "${_dest}" "${_source}")" "${initdir}/${_dest}"
    }
fi

get_persistent_dev() {
    local i _tmp _dev

    _dev=$(udevadm info --query=name --name="$1" 2>/dev/null)
    [ -z "$_dev" ] && return

    for i in /dev/mapper/* /dev/disk/by-uuid/* /dev/disk/by-id/*; do
        [[ $i == /dev/mapper/mpath* ]] && continue
        _tmp=$(udevadm info --query=name --name="$i" 2>/dev/null)
        if [ "$_tmp" = "$_dev" ]; then
            printf -- "%s" "$i"
            return
        fi
    done
}

# get_fs_env <device>
# Get and set the ID_FS_TYPE variable from udev for a device.
# Example:
# $ get_fs_env /dev/sda2; echo $ID_FS_TYPE
# ext4
get_fs_env() {
    local evalstr
    local found

    [[ $1 ]] || return
    unset ID_FS_TYPE
    if ID_FS_TYPE=$(udevadm info --query=env --name="$1" \
        | { while read line; do
                    [[ "$line" == DEVPATH\=* ]] && found=1;
                    if [[ "$line" == ID_FS_TYPE\=* ]]; then
                        printf "%s" "${line#ID_FS_TYPE=}";
                        exit 0;
                    fi
            done; [[ $found ]] && exit 0; exit 1; }) ; then
        if [[ $ID_FS_TYPE ]]; then
            printf "%s" "$ID_FS_TYPE"
            return 0
        fi
        return 1
    fi

    # Fallback, if we don't have udev information
    if find_binary blkid >/dev/null; then
        ID_FS_TYPE=$(blkid -u filesystem -o export -- "$1" \
            | while read line; do
                if [[ "$line" == TYPE\=* ]]; then
                    printf "%s" "${line#TYPE=}";
                    exit 0;
                fi
                done)
        if [[ $ID_FS_TYPE ]]; then
            printf "%s" "$ID_FS_TYPE"
            return 0
        fi
    fi
    return 1
}

# get_maj_min <device>
# Prints the major and minor of a device node.
# Example:
# $ get_maj_min /dev/sda2
# 8:2
get_maj_min() {
    local _maj _min
    read _maj _min < <(stat -L -c '%t %T' "$1" 2>/dev/null)
    printf "%s" "$((0x$_maj)):$((0x$_min))"
}

# find_block_device <mountpoint>
# Prints the major and minor number of the block device
# for a given mountpoint.
# Unless $use_fstab is set to "yes" the functions
# uses /proc/self/mountinfo as the primary source of the
# information and only falls back to /etc/fstab, if the mountpoint
# is not found there.
# Example:
# $ find_block_device /usr
# 8:4
find_block_device() {
    local _majmin _dev _majmin _find_mpt
    _find_mpt="$1"
    if [[ $use_fstab != yes ]]; then
        [[ -d $_find_mpt/. ]]
        while read _majmin _dev; do
            if [[ -b $_dev ]]; then
                if ! [[ $_majmin ]] || [[ $_majmin == 0:* ]]; then
                    read _majmin < <(get_maj_min $_dev)
                fi
                if [[ $_majmin ]]; then
                    echo $_majmin
                else
                    echo $_dev
                fi
                return 0
            fi
            if [[ $_dev = *:* ]]; then
                echo $_dev
                return 0
            fi
        done < <(findmnt -e -v -n -o 'MAJ:MIN,SOURCE' --target "$_find_mpt")
    fi
    # fall back to /etc/fstab

    while read _majmin _dev; do
        if ! [[ $_dev ]]; then
            _dev="$_majmin"
            unset _majmin
        fi
        if [[ -b $_dev ]]; then
            [[ $_majmin ]] || read _majmin < <(get_maj_min $_dev)
            if [[ $_majmin ]]; then
                echo $_majmin
            else
                echo $_dev
            fi
            return 0
        fi
        if [[ $_dev = *:* ]]; then
            echo $_dev
            return 0
        fi
    done < <(findmnt -e --fstab -v -n -o 'MAJ:MIN,SOURCE' --target "$_find_mpt")

    return 1
}

# find_mp_fstype <mountpoint>
# Echo the filesystem type for a given mountpoint.
# /proc/self/mountinfo is taken as the primary source of information
# and /etc/fstab is used as a fallback.
# No newline is appended!
# Example:
# $ find_mp_fstype /;echo
# ext4
find_mp_fstype() {
    local _fs

    if [[ $use_fstab != yes ]]; then
        while read _fs; do
            [[ $_fs ]] || continue
            [[ $_fs = "autofs" ]] && continue
            echo -n $_fs
            return 0
        done < <(findmnt -e -v -n -o 'FSTYPE' --target "$1")
    fi

    while read _fs; do
        [[ $_fs ]] || continue
        [[ $_fs = "autofs" ]] && continue
        echo -n $_fs
        return 0
    done < <(findmnt --fstab -e -v -n -o 'FSTYPE' --target "$1")

    return 1
}

# find_dev_fstype <device>
# Echo the filesystem type for a given device.
# /proc/self/mountinfo is taken as the primary source of information
# and /etc/fstab is used as a fallback.
# No newline is appended!
# Example:
# $ find_dev_fstype /dev/sda2;echo
# ext4
find_dev_fstype() {
    local _find_dev _fs
    _find_dev="$1"
    [[ "$_find_dev" = /dev* ]] || _find_dev="/dev/block/$_find_dev"

    if [[ $use_fstab != yes ]]; then
        while read _fs; do
            [[ $_fs ]] || continue
            [[ $_fs = "autofs" ]] && continue
            echo -n $_fs
            return 0
        done < <(findmnt -e -v -n -o 'FSTYPE' --source "$_find_dev")
    fi

    while read _fs; do
        [[ $_fs ]] || continue
        [[ $_fs = "autofs" ]] && continue
        echo -n $_fs
        return 0
    done < <(findmnt --fstab -e -v -n -o 'FSTYPE' --source "$_find_dev")

    return 1

}

# finds the major:minor of the block device backing the root filesystem.
find_root_block_device() { find_block_device /; }

# for_each_host_dev_fs <func>
# Execute "<func> <dev> <filesystem>" for every "<dev> <fs>" pair found
# in ${host_fs_types[@]}
for_each_host_dev_fs()
{
    local _func="$1"
    local _dev
    local _ret=1

    [[ "${!host_fs_types[@]}" ]] || return 0

    for _dev in "${!host_fs_types[@]}"; do
        $_func "$_dev" "${host_fs_types[$_dev]}" && _ret=0
    done
    return $_ret
}

host_fs_all()
{
    echo "${host_fs_types[@]}"
}

# Walk all the slave relationships for a given block device.
# Stop when our helper function returns success
# $1 = function to call on every found block device
# $2 = block device in major:minor format
check_block_and_slaves() {
    local _x
    [[ -b /dev/block/$2 ]] || return 1 # Not a block device? So sorry.
    "$1" $2 && return
    check_vol_slaves "$@" && return 0
    if [[ -f /sys/dev/block/$2/../dev ]]; then
        check_block_and_slaves $1 $(cat "/sys/dev/block/$2/../dev") && return 0
    fi
    [[ -d /sys/dev/block/$2/slaves ]] || return 1
    for _x in /sys/dev/block/$2/slaves/*/dev; do
        [[ -f $_x ]] || continue
        check_block_and_slaves $1 $(cat "$_x") && return 0
    done
    return 1
}

check_block_and_slaves_all() {
    local _x _ret=1
    [[ -b /dev/block/$2 ]] || return 1 # Not a block device? So sorry.
    if "$1" $2; then
          _ret=0
    fi
    check_vol_slaves "$@" && return 0
    if [[ -f /sys/dev/block/$2/../dev ]]; then
        check_block_and_slaves_all $1 $(cat "/sys/dev/block/$2/../dev") && _ret=0
    fi
    [[ -d /sys/dev/block/$2/slaves ]] || return 1
    for _x in /sys/dev/block/$2/slaves/*/dev; do
        [[ -f $_x ]] || continue
        check_block_and_slaves_all $1 $(cat "$_x") && _ret=0
    done
    return $_ret
}
# for_each_host_dev_and_slaves <func>
# Execute "<func> <dev>" for every "<dev>" found
# in ${host_devs[@]} and their slaves
for_each_host_dev_and_slaves_all()
{
    local _func="$1"
    local _dev
    local _ret=1

    [[ "${host_devs[@]}" ]] || return 0

    for _dev in ${host_devs[@]}; do
        [[ -b "$_dev" ]] || continue
        if check_block_and_slaves_all $_func $(get_maj_min $_dev); then
               _ret=0
        fi
    done
    return $_ret
}

for_each_host_dev_and_slaves()
{
    local _func="$1"
    local _dev

    [[ "${host_devs[@]}" ]] || return 0

    for _dev in ${host_devs[@]}; do
        [[ -b "$_dev" ]] || continue
        check_block_and_slaves $_func $(get_maj_min $_dev) && return 0
    done
    return 1
}

# ugly workaround for the lvm design
# There is no volume group device,
# so, there are no slave devices for volume groups.
# Logical volumes only have the slave devices they really live on,
# but you cannot create the logical volume without the volume group.
# And the volume group might be bigger than the devices the LV needs.
check_vol_slaves() {
    local _lv _vg _pv
    for i in /dev/mapper/*; do
        _lv=$(get_maj_min $i)
        if [[ $_lv = $2 ]]; then
            _vg=$(lvm lvs --noheadings -o vg_name $i 2>/dev/null)
            # strip space
            _vg=$(echo $_vg)
            if [[ $_vg ]]; then
                for _pv in $(lvm vgs --noheadings -o pv_name "$_vg" 2>/dev/null)
                do
                    check_block_and_slaves $1 $(get_maj_min $_pv) && return 0
                done
            fi
        fi
    done
    return 1
}

# fs_get_option <filesystem options> <search for option>
# search for a specific option in a bunch of filesystem options
# and return the value
fs_get_option() {
    local _fsopts=$1
    local _option=$2
    local OLDIFS="$IFS"
    IFS=,
    set -- $_fsopts
    IFS="$OLDIFS"
    while [ $# -gt 0 ]; do
        case $1 in
            $_option=*)
                echo ${1#${_option}=}
                break
        esac
        shift
    done
}

if [[ $DRACUT_INSTALL ]]; then
    [[ $DRACUT_RESOLVE_LAZY ]] || export DRACUT_RESOLVE_DEPS=1
    inst_dir() {
        [[ -e ${initdir}/"$1" ]] && return 0  # already there
        $DRACUT_INSTALL ${initdir+-D "$initdir"} -d "$@"
        (($? != 0)) && derror $DRACUT_INSTALL ${initdir+-D "$initdir"} -d "$@" || :
    }

    inst() {
        [[ -e ${initdir}/"${2:-$1}" ]] && return 0  # already there
        #dinfo "$DRACUT_INSTALL -l $@"
        $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l} ${DRACUT_FIPS_MODE+-H} "$@"
        (($? != 0)) && derror $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l} ${DRACUT_FIPS_MODE+-H} "$@" || :
    }

    inst_simple() {
        [[ -e ${initdir}/"${2:-$1}" ]] && return 0  # already there
        [[ -e $1 ]] || return 1  # no source
        $DRACUT_INSTALL ${initdir+-D "$initdir"} "$@"
        (($? != 0)) && derror $DRACUT_INSTALL ${initdir+-D "$initdir"} "$@" || :
    }

    inst_symlink() {
        [[ -e ${initdir}/"${2:-$1}" ]] && return 0  # already there
        [[ -L $1 ]] || return 1
        $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@"
        (($? != 0)) && derror $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@" || :
    }

    dracut_install() {
        local ret
        #dinfo "initdir=$initdir $DRACUT_INSTALL -l $@"
        $DRACUT_INSTALL ${initdir+-D "$initdir"} -a ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@"
        ret=$?
        (($ret != 0)) && derror $DRACUT_INSTALL ${initdir+-D "$initdir"} -a ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@" || :
        return $ret
    }

    inst_library() {
        [[ -e ${initdir}/"${2:-$1}" ]] && return 0  # already there
        [[ -e $1 ]] || return 1  # no source
        $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@"
        (($? != 0)) && derror $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@" || :
    }

    inst_binary() {
        $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@"
        (($? != 0)) && derror $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@" || :
    }

    inst_script() {
        $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@"
        (($? != 0)) && derror $DRACUT_INSTALL ${initdir+-D "$initdir"} ${DRACUT_RESOLVE_DEPS+-l}  ${DRACUT_FIPS_MODE+-H} "$@" || :
    }

else

    # Install a directory, keeping symlinks as on the original system.
    # Example: if /lib points to /lib64 on the host, "inst_dir /lib/file"
    # will create ${initdir}/lib64, ${initdir}/lib64/file,
    # and a symlink ${initdir}/lib -> lib64.
    inst_dir() {
        [[ -e ${initdir}/"$1" ]] && return 0  # already there

        local _dir="$1" _part="${1%/*}" _file
        while [[ "$_part" != "${_part%/*}" ]] && ! [[ -e "${initdir}/${_part}" ]]; do
            _dir="$_part $_dir"
            _part=${_part%/*}
        done

        # iterate over parent directories
        for _file in $_dir; do
            [[ -e "${initdir}/$_file" ]] && continue
            if [[ -L $_file ]]; then
                inst_symlink "$_file"
            else
            # create directory
                mkdir -m 0755 -p "${initdir}/$_file" || return 1
                [[ -e "$_file" ]] && chmod --reference="$_file" "${initdir}/$_file"
                chmod u+w "${initdir}/$_file"
            fi
        done
    }

    # $1 = file to copy to ramdisk
    # $2 (optional) Name for the file on the ramdisk
    # Location of the image dir is assumed to be $initdir
    # We never overwrite the target if it exists.
    inst_simple() {
        [[ -f "$1" ]] || return 1
        [[ "$1" == */* ]] || return 1
        local _src=$1 _target="${2:-$1}"

        [[ -L $_src ]] && { inst_symlink $_src $_target; return $?; }

        if ! [[ -d ${initdir}/$_target ]]; then
            [[ -e ${initdir}/$_target ]] && return 0
            [[ -L ${initdir}/$_target ]] && return 0
            [[ -d "${initdir}/${_target%/*}" ]] || inst_dir "${_target%/*}"
        fi
        if [[ $DRACUT_FIPS_MODE ]]; then
            # install checksum files also
            if [[ -e "${_src%/*}/.${_src##*/}.hmac" ]]; then
                inst "${_src%/*}/.${_src##*/}.hmac" "${_target%/*}/.${_target##*/}.hmac"
            fi
            if [[ -e "/lib/fipscheck/${_src##*/}.hmac" ]]; then
                inst "/lib/fipscheck/${_src##*/}.hmac" "/lib/fipscheck/${_target##*/}.hmac"
            fi
            if [[ -e "/lib64/fipscheck/${_src##*/}.hmac" ]]; then
                inst "/lib64/fipscheck/${_src##*/}.hmac" "/lib64/fipscheck/${_target##*/}.hmac"
            fi
        fi
        ddebug "Installing $_src"
        cp --reflink=auto --sparse=auto -pfL "$_src" "${initdir}/$_target"
    }

    # same as above, but specialized for symlinks
    inst_symlink() {
        local _src=$1 _target=${2:-$1} _realsrc
        [[ "$1" == */* ]] || return 1
        [[ -L $1 ]] || return 1
        [[ -L $initdir/$_target ]] && return 0
        _realsrc=$(readlink -f "$_src")
        if ! [[ -e $initdir/$_realsrc ]]; then
            if [[ -d $_realsrc ]]; then
                inst_dir "$_realsrc"
            else
                inst "$_realsrc"
            fi
        fi
        [[ ! -e $initdir/${_target%/*} ]] && inst_dir "${_target%/*}"

        ln_r "${_realsrc}" "${_target}"
    }

    # Same as above, but specialized to handle dynamic libraries.
    # It handles making symlinks according to how the original library
    # is referenced.
    inst_library() {
        local _src="$1" _dest=${2:-$1} _lib _reallib _symlink
        [[ "$1" == */* ]] || return 1
        [[ -e $initdir/$_dest ]] && return 0
        if [[ -L $_src ]]; then
            if [[ $DRACUT_FIPS_MODE ]]; then
                # install checksum files also
                if [[ -e "${_src%/*}/.${_src##*/}.hmac" ]]; then
                    inst "${_src%/*}/.${_src##*/}.hmac" "${_dest%/*}/.${_dest##*/}.hmac"
                fi
                if [[ -e "/lib/fipscheck/${_src##*/}.hmac" ]]; then
                    inst "/lib/fipscheck/${_src##*/}.hmac" "/lib/fipscheck/${_dest##*/}.hmac"
                fi
                if [[ -e "/lib64/fipscheck/${_src##*/}.hmac" ]]; then
                    inst "/lib64/fipscheck/${_src##*/}.hmac" "/lib64/fipscheck/${_dest##*/}.hmac"
                fi
            fi
            _reallib=$(readlink -f "$_src")
            inst_simple "$_reallib" "$_reallib"
            inst_dir "${_dest%/*}"
            ln_r "${_reallib}" "${_dest}"
        else
            inst_simple "$_src" "$_dest"
        fi

        # Create additional symlinks.  See rev_symlinks description.
        for _symlink in $(rev_lib_symlinks $_src) $(rev_lib_symlinks $_reallib); do
            [[ ! -e $initdir/$_symlink ]] && {
                ddebug "Creating extra symlink: $_symlink"
                inst_symlink $_symlink
            }
        done
    }

    # Same as above, but specialized to install binary executables.
    # Install binary executable, and all shared library dependencies, if any.
    inst_binary() {
        local _bin _target
        _bin=$(find_binary "$1") || return 1
        _target=${2:-$_bin}
        [[ -e $initdir/$_target ]] && return 0
        local _file _line
        local _so_regex='([^ ]*/lib[^/]*/[^ ]*\.so[^ ]*)'
        # I love bash!
        LC_ALL=C ldd "$_bin" 2>/dev/null | while read _line; do
            [[ $_line = 'not a dynamic executable' ]] && break

            if [[ $_line =~ $_so_regex ]]; then
                _file=${BASH_REMATCH[1]}
                [[ -e ${initdir}/$_file ]] && continue
                inst_library "$_file"
                continue
            fi

            if [[ $_line == *not\ found* ]]; then
                dfatal "Missing a shared library required by $_bin."
                dfatal "Run \"ldd $_bin\" to find out what it is."
                dfatal "$_line"
                dfatal "dracut cannot create an initrd."
                exit 1
            fi
        done
        inst_simple "$_bin" "$_target"
    }

    # same as above, except for shell scripts.
    # If your shell script does not start with shebang, it is not a shell script.
    inst_script() {
        local _bin
        _bin=$(find_binary "$1") || return 1
        shift
        local _line _shebang_regex
        read -r -n 80 _line <"$_bin"
        # If debug is set, clean unprintable chars to prevent messing up the term
        [[ $debug ]] && _line=$(echo -n "$_line" | tr -c -d '[:print:][:space:]')
        _shebang_regex='(#! *)(/[^ ]+).*'
        [[ $_line =~ $_shebang_regex ]] || return 1
        inst "${BASH_REMATCH[2]}" && inst_simple "$_bin" "$@"
    }

    # general purpose installation function
    # Same args as above.
    inst() {
        local _x

        case $# in
            1) ;;
            2) [[ ! $initdir && -d $2 ]] && export initdir=$2
                [[ $initdir = $2 ]] && set $1;;
            3) [[ -z $initdir ]] && export initdir=$2
                set $1 $3;;
            *) dfatal "inst only takes 1 or 2 or 3 arguments"
                exit 1;;
        esac
        for _x in inst_symlink inst_script inst_binary inst_simple; do
            $_x "$@" && return 0
        done
        return 1
    }

    # dracut_install [-o ] <file> [<file> ... ]
    # Install <file> to the initramfs image
    # -o optionally install the <file> and don't fail, if it is not there
    dracut_install() {
        local _optional=no
        if [[ $1 = '-o' ]]; then
            _optional=yes
            shift
        fi
        while (($# > 0)); do
            if ! inst "$1" ; then
                if [[ $_optional = yes ]]; then
                    dinfo "Skipping program $1 as it cannot be found and is" \
                        "flagged to be optional"
                else
                    dfatal "Failed to install $1"
                    exit 1
                fi
            fi
            shift
        done
    }

fi

# find symlinks linked to given library file
# $1 = library file
# Function searches for symlinks by stripping version numbers appended to
# library filename, checks if it points to the same target and finally
# prints the list of symlinks to stdout.
#
# Example:
# rev_lib_symlinks libfoo.so.8.1
# output: libfoo.so.8 libfoo.so
# (Only if libfoo.so.8 and libfoo.so exists on host system.)
rev_lib_symlinks() {
    [[ ! $1 ]] && return 0

    local fn="$1" orig="$(readlink -f "$1")" links=''

    [[ ${fn} == *.so.* ]] || return 1

    until [[ ${fn##*.} == so ]]; do
        fn="${fn%.*}"
        [[ -L ${fn} && $(readlink -f "${fn}") == ${orig} ]] && links+=" ${fn}"
    done

    echo "${links}"
}

# attempt to install any programs specified in a udev rule
inst_rule_programs() {
    local _prog _bin

    if grep -qE 'PROGRAM==?"[^ "]+' "$1"; then
        for _prog in $(grep -E 'PROGRAM==?"[^ "]+' "$1" | sed -r 's/.*PROGRAM==?"([^ "]+).*/\1/'); do
            _bin=""
            if [ -x ${udevdir}/$_prog ]; then
                _bin=${udevdir}/$_prog
            elif [[ "${_prog/\$env\{/}" == "$_prog" ]]; then
                _bin=$(find_binary "$_prog") || {
                    dinfo "Skipping program $_prog using in udev rule ${1##*/} as it cannot be found"
                    continue;
                }
            fi

            [[ $_bin ]] && dracut_install "$_bin"
        done
    fi
    if grep -qE 'RUN[+=]=?"[^ "]+' "$1"; then
        for _prog in $(grep -E 'RUN[+=]=?"[^ "]+' "$1" | sed -r 's/.*RUN[+=]=?"([^ "]+).*/\1/'); do
            _bin=""
            if [ -x ${udevdir}/$_prog ]; then
                _bin=${udevdir}/$_prog
            elif [[ "${_prog/\$env\{/}" == "$_prog" ]] && [[ "${_prog}" != "/sbin/initqueue" ]]; then
                _bin=$(find_binary "$_prog") || {
                    dinfo "Skipping program $_prog using in udev rule ${1##*/} as it cannot be found"
                    continue;
                }
            fi

            [[ $_bin ]] && dracut_install "$_bin"
        done
    fi
    if grep -qE 'IMPORT\{program\}==?"[^ "]+' "$1"; then
        for _prog in $(grep -E 'IMPORT\{program\}==?"[^ "]+' "$1" | sed -r 's/.*IMPORT\{program\}==?"([^ "]+).*/\1/'); do
            _bin=""
            if [ -x ${udevdir}/$_prog ]; then
                _bin=${udevdir}/$_prog
            elif [[ "${_prog/\$env\{/}" == "$_prog" ]]; then
                _bin=$(find_binary "$_prog") || {
                    dinfo "Skipping program $_prog using in udev rule ${1##*/} as it cannot be found"
                    continue;
                }
            fi

            [[ $_bin ]] && dracut_install "$_bin"
        done
    fi
}

# attempt to install any programs specified in a udev rule
inst_rule_group_owner() {
    local i

    if grep -qE 'OWNER=?"[^ "]+' "$1"; then
        for i in $(grep -E 'OWNER=?"[^ "]+' "$1" | sed -r 's/.*OWNER=?"([^ "]+).*/\1/'); do
            if ! egrep -q "^$i:" "$initdir/etc/passwd" 2>/dev/null; then
                egrep "^$i:" /etc/passwd 2>/dev/null >> "$initdir/etc/passwd"
            fi
        done
    fi
    if grep -qE 'GROUP=?"[^ "]+' "$1"; then
        for i in $(grep -E 'GROUP=?"[^ "]+' "$1" | sed -r 's/.*GROUP=?"([^ "]+).*/\1/'); do
            if ! egrep -q "^$i:" "$initdir/etc/group" 2>/dev/null; then
                egrep "^$i:" /etc/group 2>/dev/null >> "$initdir/etc/group"
            fi
        done
    fi
}

inst_rule_initqueue() {
    if grep -q -F initqueue "$1"; then
        dracut_need_initqueue
    fi
}

# udev rules always get installed in the same place, so
# create a function to install them to make life simpler.
inst_rules() {
    local _target=/etc/udev/rules.d _rule _found

    inst_dir "${udevdir}/rules.d"
    inst_dir "$_target"
    for _rule in "$@"; do
        if [ "${_rule#/}" = "$_rule" ]; then
            for r in ${udevdir}/rules.d /etc/udev/rules.d; do
                if [[ -f $r/$_rule ]]; then
                    _found="$r/$_rule"
                    inst_rule_programs "$_found"
                    inst_rule_group_owner "$_found"
                    inst_rule_initqueue "$_found"
                    inst_simple "$_found"
                fi
            done
        fi
        for r in '' ./ $dracutbasedir/rules.d/; do
            if [[ -f ${r}$_rule ]]; then
                _found="${r}$_rule"
                inst_rule_programs "$_found"
                inst_rule_group_owner "$_found"
                inst_rule_initqueue "$_found"
                inst_simple "$_found" "$_target/${_found##*/}"
            fi
        done
        [[ $_found ]] || dinfo "Skipping udev rule: $_rule"
    done
}

prepare_udev_rules() {
    [ -z "$UDEVVERSION" ] && export UDEVVERSION=$(udevadm --version)

    for f in "$@"; do
        f="${initdir}/etc/udev/rules.d/$f"
        [ -e "$f" ] || continue
        while read line; do
            if [ "${line%%IMPORT PATH_ID}" != "$line" ]; then
                if [ $UDEVVERSION -ge 174 ]; then
                    printf '%sIMPORT{builtin}="path_id"\n' "${line%%IMPORT PATH_ID}"
                else
                    printf '%sIMPORT{program}="path_id %%p"\n' "${line%%IMPORT PATH_ID}"
                fi
            elif [ "${line%%IMPORT BLKID}" != "$line" ]; then
                if [ $UDEVVERSION -ge 176 ]; then
                    printf '%sIMPORT{builtin}="blkid"\n' "${line%%IMPORT BLKID}"
                else
                    printf '%sIMPORT{program}="/sbin/blkid -o udev -p $tempnode"\n' "${line%%IMPORT BLKID}"
                fi
            else
                echo "$line"
            fi
        done < "${f}" > "${f}.new"
        mv "${f}.new" "$f"
    done
}

# install function specialized for hooks
# $1 = type of hook, $2 = hook priority (lower runs first), $3 = hook
# All hooks should be POSIX/SuS compliant, they will be sourced by init.
inst_hook() {
    if ! [[ -f $3 ]]; then
        dfatal "Cannot install a hook ($3) that does not exist."
        dfatal "Aborting initrd creation."
        exit 1
    elif ! [[ "$hookdirs" == *$1* ]]; then
        dfatal "No such hook type $1. Aborting initrd creation."
        exit 1
    fi
    inst_simple "$3" "/lib/dracut/hooks/${1}/${2}-${3##*/}"
}

# install any of listed files
#
# If first argument is '-d' and second some destination path, first accessible
# source is installed into this path, otherwise it will installed in the same
# path as source.  If none of listed files was installed, function return 1.
# On first successful installation it returns with 0 status.
#
# Example:
#
# inst_any -d /bin/foo /bin/bar /bin/baz
#
# Lets assume that /bin/baz exists, so it will be installed as /bin/foo in
# initramfs.
inst_any() {
    local to f

    [[ $1 = '-d' ]] && to="$2" && shift 2

    for f in "$@"; do
        if [[ -e $f ]]; then
            [[ $to ]] && inst "$f" "$to" && return 0
            inst "$f" && return 0
        fi
    done

    return 1
}


# inst_libdir_file [-n <pattern>] <file> [<file>...]
# Install a <file> located on a lib directory to the initramfs image
# -n <pattern> install matching files
inst_libdir_file() {
    local _files
    if [[ "$1" == "-n" ]]; then
        local _pattern=$2
        shift 2
        for _dir in $libdirs; do
            for _i in "$@"; do
                for _f in "$_dir"/$_i; do
                    [[ "$_f" =~ $_pattern ]] || continue
                    [[ -e "$_f" ]] && _files+="$_f "
                done
            done
        done
    else
        for _dir in $libdirs; do
            for _i in "$@"; do
                for _f in "$_dir"/$_i; do
                    [[ -e "$_f" ]] && _files+="$_f "
                done
            done
        done
    fi
    [[ $_files ]] && dracut_install $_files
}


# install function decompressing the target and handling symlinks
# $@ = list of compressed (gz or bz2) files or symlinks pointing to such files
#
# Function install targets in the same paths inside overlay but decompressed
# and without extensions (.gz, .bz2).
inst_decompress() {
    local _src _cmd

    for _src in $@
    do
        case ${_src} in
            *.gz) _cmd='gzip -f -d' ;;
            *.bz2) _cmd='bzip2 -d' ;;
            *) return 1 ;;
        esac
        inst_simple ${_src}
        # Decompress with chosen tool.  We assume that tool changes name e.g.
        # from 'name.gz' to 'name'.
        ${_cmd} "${initdir}${_src}"
    done
}

# It's similar to above, but if file is not compressed, performs standard
# install.
# $@ = list of files
inst_opt_decompress() {
    local _src

    for _src in $@
    do
        inst_decompress "${_src}" || inst "${_src}"
    done
}

# module_check <dracut module>
# execute the check() function of module-setup.sh of <dracut module>
# or the "check" script, if module-setup.sh is not found
# "check $hostonly" is called
module_check() {
    local _moddir=$(echo ${dracutbasedir}/modules.d/??${1})
    local _ret
    local _forced=0
    local _hostonly=$hostonly
    [ $# -eq 2 ] && _forced=$2
    [[ -d $_moddir ]] || return 1
    if [[ ! -f $_moddir/module-setup.sh ]]; then
        # if we do not have a check script, we are unconditionally included
        [[ -x $_moddir/check ]] || return 0
        [ $_forced -ne 0 ] && unset hostonly
        $_moddir/check $hostonly
        _ret=$?
    else
        unset check depends install installkernel
        check() { true; }
        . $_moddir/module-setup.sh
        is_func check || return 0
        [ $_forced -ne 0 ] && unset hostonly
        check $hostonly
        _ret=$?
        unset check depends install installkernel
    fi
    hostonly=$_hostonly
    return $_ret
}

# module_check_mount <dracut module>
# execute the check() function of module-setup.sh of <dracut module>
# or the "check" script, if module-setup.sh is not found
# "mount_needs=1 check 0" is called
module_check_mount() {
    local _moddir=$(echo ${dracutbasedir}/modules.d/??${1})
    local _ret
    mount_needs=1
    [[ -d $_moddir ]] || return 1
    if [[ ! -f $_moddir/module-setup.sh ]]; then
        # if we do not have a check script, we are unconditionally included
        [[ -x $_moddir/check ]] || return 0
        mount_needs=1 $_moddir/check 0
        _ret=$?
    else
        unset check depends install installkernel
        check() { false; }
        . $_moddir/module-setup.sh
        check 0
        _ret=$?
        unset check depends install installkernel
    fi
    unset mount_needs
    return $_ret
}

# module_depends <dracut module>
# execute the depends() function of module-setup.sh of <dracut module>
# or the "depends" script, if module-setup.sh is not found
module_depends() {
    local _moddir=$(echo ${dracutbasedir}/modules.d/??${1})
    local _ret
    [[ -d $_moddir ]] || return 1
    if [[ ! -f $_moddir/module-setup.sh ]]; then
        # if we do not have a check script, we have no deps
        [[ -x $_moddir/check ]] || return 0
        $_moddir/check -d
        return $?
    else
        unset check depends install installkernel
        depends() { true; }
        . $_moddir/module-setup.sh
        depends
        _ret=$?
        unset check depends install installkernel
        return $_ret
    fi
}

# module_install <dracut module>
# execute the install() function of module-setup.sh of <dracut module>
# or the "install" script, if module-setup.sh is not found
module_install() {
    local _moddir=$(echo ${dracutbasedir}/modules.d/??${1})
    local _ret
    [[ -d $_moddir ]] || return 1
    if [[ ! -f $_moddir/module-setup.sh ]]; then
        [[ -x $_moddir/install ]] && . "$_moddir/install"
        return $?
    else
        unset check depends install installkernel
        install() { true; }
        . $_moddir/module-setup.sh
        install
        _ret=$?
        unset check depends install installkernel
        return $_ret
    fi
}

# module_installkernel <dracut module>
# execute the installkernel() function of module-setup.sh of <dracut module>
# or the "installkernel" script, if module-setup.sh is not found
module_installkernel() {
    local _moddir=$(echo ${dracutbasedir}/modules.d/??${1})
    local _ret
    [[ -d $_moddir ]] || return 1
    if [[ ! -f $_moddir/module-setup.sh ]]; then
        [[ -x $_moddir/installkernel ]] && . "$_moddir/installkernel"
        return $?
    else
        unset check depends install installkernel
        installkernel() { true; }
       . $_moddir/module-setup.sh
        installkernel
        _ret=$?
        unset check depends install installkernel
        return $_ret
    fi
}

# check_mount <dracut module>
# check_mount checks, if a dracut module is needed for the given
# device and filesystem types in "${host_fs_types[@]}"
check_mount() {
    local _mod=$1
    local _moddir=$(echo ${dracutbasedir}/modules.d/??${1})
    local _ret
    local _moddep

    [ "${#host_fs_types[*]}" -le 0 ] && return 1

    # If we are already scheduled to be loaded, no need to check again.
    [[ " $mods_to_load " == *\ $_mod\ * ]] && return 0
    [[ " $mods_checked_as_dep " == *\ $_mod\ * ]] && return 1

    # This should never happen, but...
    [[ -d $_moddir ]] || return 1

    [[ $2 ]] || mods_checked_as_dep+=" $_mod "

    if [[ " $omit_dracutmodules " == *\ $_mod\ * ]]; then
        dinfo "dracut module '$_mod' will not be installed, because it's in the list to be omitted!"
        return 1
    fi

    if [[ " $dracutmodules $add_dracutmodules $force_add_dracutmodules" == *\ $_mod\ * ]]; then
        module_check_mount $_mod; ret=$?

        # explicit module, so also accept ret=255
        [[ $ret = 0 || $ret = 255 ]] || return 1
    else
        # module not in our list
        if [[ $dracutmodules = all ]]; then
            # check, if we can and should install this module
            module_check_mount $_mod || return 1
        else
            # skip this module
            return 1
        fi
    fi


    for _moddep in $(module_depends $_mod); do
        # handle deps as if they were manually added
        [[ " $add_dracutmodules " == *\ $_moddep\ * ]] || \
            add_dracutmodules+=" $_moddep "
        [[ " $force_add_dracutmodules " == *\ $_moddep\ * ]] || \
            force_add_dracutmodules+=" $_moddep "
        # if a module we depend on fail, fail also
        if ! check_module $_moddep; then
            derror "dracut module '$_mod' depends on '$_moddep', which can't be installed"
            return 1
        fi
    done

    [[ " $mods_to_load " == *\ $_mod\ * ]] || \
        mods_to_load+=" $_mod "

    return 0
}

# check_module <dracut module> [<use_as_dep>]
# check if a dracut module is to be used in the initramfs process
# if <use_as_dep> is set, then the process also keeps track
# that the modules were checked for the dependency tracking process
check_module() {
    local _mod=$1
    local _moddir=$(echo ${dracutbasedir}/modules.d/??${1})
    local _ret
    local _moddep
    # If we are already scheduled to be loaded, no need to check again.
    [[ " $mods_to_load " == *\ $_mod\ * ]] && return 0
    [[ " $mods_checked_as_dep " == *\ $_mod\ * ]] && return 1

    # This should never happen, but...
    [[ -d $_moddir ]] || return 1

    [[ $2 ]] || mods_checked_as_dep+=" $_mod "

    if [[ " $omit_dracutmodules " == *\ $_mod\ * ]]; then
        dinfo "dracut module '$_mod' will not be installed, because it's in the list to be omitted!"
        return 1
    fi

    if [[ " $dracutmodules $add_dracutmodules $force_add_dracutmodules" == *\ $_mod\ * ]]; then
        if [[ " $force_add_dracutmodules " == *\ $_mod\ * ]]; then
            module_check $_mod 1; ret=$?
        else
            module_check $_mod 0; ret=$?
        fi
        # explicit module, so also accept ret=255
        [[ $ret = 0 || $ret = 255 ]] || return 1
    else
        # module not in our list
        if [[ $dracutmodules = all ]]; then
            # check, if we can and should install this module
            module_check $_mod || return 1
        else
            # skip this module
            return 1
        fi
    fi

    for _moddep in $(module_depends $_mod); do
        # handle deps as if they were manually added
        [[ " $add_dracutmodules " == *\ $_moddep\ * ]] || \
            add_dracutmodules+=" $_moddep "
        [[ " $force_add_dracutmodules " == *\ $_moddep\ * ]] || \
            force_add_dracutmodules+=" $_moddep "
        # if a module we depend on fail, fail also
        if ! check_module $_moddep; then
            derror "dracut module '$_mod' depends on '$_moddep', which can't be installed"
            return 1
        fi
    done

    [[ " $mods_to_load " == *\ $_mod\ * ]] || \
        mods_to_load+=" $_mod "

    return 0
}

# for_each_module_dir <func>
# execute "<func> <dracut module> 1"
for_each_module_dir() {
    local _modcheck
    local _mod
    local _moddir
    local _func
    _func=$1
    for _moddir in "$dracutbasedir/modules.d"/[0-9][0-9]*; do
        _mod=${_moddir##*/}; _mod=${_mod#[0-9][0-9]}
        $_func $_mod 1
    done

    # Report any missing dracut modules, the user has specified
    _modcheck="$add_dracutmodules $force_add_dracutmodules"
    [[ $dracutmodules != all ]] && _modcheck="$m $dracutmodules"
    for _mod in $_modcheck; do
        [[ " $mods_to_load " == *\ $_mod\ * ]] && continue
        [[ " $omit_dracutmodules " == *\ $_mod\ * ]] && continue
        derror "dracut module '$_mod' cannot be found or installed."
    done
}

# Install a single kernel module along with any firmware it may require.
# $1 = full path to kernel module to install
install_kmod_with_fw() {
    # no need to go further if the module is already installed

    [[ -e "${initdir}/lib/modules/$kernel/${1##*/lib/modules/$kernel/}" ]] \
        && return 0

    if [[ $DRACUT_KERNEL_LAZY_HASHDIR ]] && [[ -e "$DRACUT_KERNEL_LAZY_HASHDIR/${1##*/}" ]]; then
        read ret < "$DRACUT_KERNEL_LAZY_HASHDIR/${1##*/}"
        return $ret
    fi

    if [[ $omit_drivers ]]; then
        local _kmod=${1##*/}
        _kmod=${_kmod%.ko}
        _kmod=${_kmod/-/_}
        if [[ "$_kmod" =~ $omit_drivers ]]; then
            dinfo "Omitting driver $_kmod"
            return 0
        fi
        if [[ "${1##*/lib/modules/$kernel/}" =~ $omit_drivers ]]; then
            dinfo "Omitting driver $_kmod"
            return 0
        fi
    fi

    inst_simple "$1" "/lib/modules/$kernel/${1##*/lib/modules/$kernel/}"
    ret=$?
    [[ $DRACUT_KERNEL_LAZY_HASHDIR ]] && \
        [[ -d "$DRACUT_KERNEL_LAZY_HASHDIR" ]] && \
        echo $ret > "$DRACUT_KERNEL_LAZY_HASHDIR/${1##*/}"
    (($ret != 0)) && return $ret

    local _modname=${1##*/} _fwdir _found _fw
    _modname=${_modname%.ko*}
    for _fw in $(modinfo -k $kernel -F firmware $1 2>/dev/null); do
        _found=''
        for _fwdir in $fw_dir; do
            if [[ -d $_fwdir && -f $_fwdir/$_fw ]]; then
                inst_simple "$_fwdir/$_fw" "/lib/firmware/$_fw"
                _found=yes
            fi
        done
        if [[ $_found != yes ]]; then
            if ! [[ -d $(echo /sys/module/${_modname//-/_}|{ read a b; echo $a; }) ]]; then
                dinfo "Possible missing firmware \"${_fw}\" for kernel module" \
                    "\"${_modname}.ko\""
            else
                dwarn "Possible missing firmware \"${_fw}\" for kernel module" \
                    "\"${_modname}.ko\""
            fi
        fi
    done
    return 0
}

# Do something with all the dependencies of a kernel module.
# Note that kernel modules depend on themselves using the technique we use
# $1 = function to call for each dependency we find
#      It will be passed the full path to the found kernel module
# $2 = module to get dependencies for
# rest of args = arguments to modprobe
# _fderr specifies FD passed from surrounding scope
for_each_kmod_dep() {
    local _func=$1 _kmod=$2 _cmd _modpath _options
    shift 2
    modprobe "$@" --ignore-install --show-depends $_kmod 2>&${_fderr} | (
        while read _cmd _modpath _options; do
            [[ $_cmd = insmod ]] || continue
            $_func ${_modpath} || exit $?
        done
    )
}

dracut_kernel_post() {
    local _moddirname=${srcmods%%/lib/modules/*}

    if [[ $DRACUT_KERNEL_LAZY_HASHDIR ]] && [[ -f "$DRACUT_KERNEL_LAZY_HASHDIR/lazylist" ]]; then
        xargs -r modprobe -a ${_moddirname+-d ${_moddirname}/} \
            --ignore-install --show-depends --set-version $kernel \
            < "$DRACUT_KERNEL_LAZY_HASHDIR/lazylist" 2>/dev/null \
            | sort -u \
            | while read _cmd _modpath _options; do
            [[ $_cmd = insmod ]] || continue
            echo "$_modpath"
        done > "$DRACUT_KERNEL_LAZY_HASHDIR/lazylist.dep"

        (
            if [[ $DRACUT_INSTALL ]] && [[ -z $_moddirname ]]; then
                xargs -r $DRACUT_INSTALL ${initdir+-D "$initdir"} -a < "$DRACUT_KERNEL_LAZY_HASHDIR/lazylist.dep"
            else
                while read _modpath; do
                    local _destpath=$_modpath
                    [[ $_moddirname ]] && _destpath=${_destpath##$_moddirname/}
                    _destpath=${_destpath##*/lib/modules/$kernel/}
                    inst_simple "$_modpath" "/lib/modules/$kernel/${_destpath}" || exit $?
                done < "$DRACUT_KERNEL_LAZY_HASHDIR/lazylist.dep"
            fi
        ) &

        if [[ $DRACUT_INSTALL ]]; then
            xargs -r modinfo -k $kernel -F firmware < "$DRACUT_KERNEL_LAZY_HASHDIR/lazylist.dep" \
                | while read line; do
                for _fwdir in $fw_dir; do
                    echo $_fwdir/$line;
                done;
            done | xargs -r $DRACUT_INSTALL ${initdir+-D "$initdir"} -a -o
        else
            for _fw in $(xargs -r modinfo -k $kernel -F firmware < "$DRACUT_KERNEL_LAZY_HASHDIR/lazylist.dep"); do
                for _fwdir in $fw_dir; do
                    if [[ -d $_fwdir && -f $_fwdir/$_fw ]]; then
                        inst_simple "$_fwdir/$_fw" "/lib/firmware/$_fw"
                        break
                    fi
                done
            done
        fi

        wait
    fi

    for _f in modules.builtin.bin modules.builtin; do
        [[ $srcmods/$_f ]] && break
    done || {
        dfatal "No modules.builtin.bin and modules.builtin found!"
        return 1
    }

    for _f in modules.builtin.bin modules.builtin modules.order; do
        [[ $srcmods/$_f ]] && inst_simple "$srcmods/$_f" "/lib/modules/$kernel/$_f"
    done

    # generate module dependencies for the initrd
    if [[ -d $initdir/lib/modules/$kernel ]] && \
        ! depmod -a -b "$initdir" $kernel; then
        dfatal "\"depmod -a $kernel\" failed."
        exit 1
    fi

    [[ $DRACUT_KERNEL_LAZY_HASHDIR ]] && rm -fr -- "$DRACUT_KERNEL_LAZY_HASHDIR"
}

module_is_host_only() { (
    local _mod=$1
    _mod=${_mod##*/}
    _mod=${_mod%.ko}

    [[ " $add_drivers " == *\ ${_mod}\ * ]] && return 0

    # check if module is loaded
    for i in /sys/module/${_mod//-/_}; do
        [[ -d $i ]] && return 0
    done

    # check if module is loadable on the current kernel
    # this covers the case, where a new module is introduced
    # or a module was renamed
    # or a module changed from builtin to a module
    modinfo -F filename "$_mod" &>/dev/null || return 0

    return 1
    )
}

find_kernel_modules_by_path () {
    local _OLDIFS

    [[ -f "$srcmods/modules.dep" ]] || return 0

    _OLDIFS=$IFS
    IFS=:
    while read a rest; do
        [[ $a = */$1/* ]] || continue
        printf "%s\n" "$srcmods/$a"
    done < "$srcmods/modules.dep"
    IFS=$_OLDIFS
    return 0
}

find_kernel_modules () {
    find_kernel_modules_by_path  drivers
}

# instmods [-c [-s]] <kernel module> [<kernel module> ... ]
# instmods [-c [-s]] <kernel subsystem>
# install kernel modules along with all their dependencies.
# <kernel subsystem> can be e.g. "=block" or "=drivers/usb/storage"
instmods() {
    [[ $no_kernel = yes ]] && return
    # called [sub]functions inherit _fderr
    local _fderr=9
    local _check=no
    local _silent=no
    if [[ $1 = '-c' ]]; then
        _check=yes
        shift
    fi

    if [[ $1 = '-s' ]]; then
        _silent=yes
        shift
    fi

    function inst1mod() {
        local _ret=0 _mod="$1"
        case $_mod in
            =*)
                ( [[ "$_mpargs" ]] && echo $_mpargs
                    find_kernel_modules_by_path "${_mod#=}" ) \
                        | instmods
                ((_ret+=$?))
                ;;
            --*) _mpargs+=" $_mod" ;;
            *)
                _mod=${_mod##*/}
                # if we are already installed, skip this module and go on
                # to the next one.
                if [[ $DRACUT_KERNEL_LAZY_HASHDIR ]] && \
                    [[ -f "$DRACUT_KERNEL_LAZY_HASHDIR/${_mod%.ko}.ko" ]]; then
                    read _ret <"$DRACUT_KERNEL_LAZY_HASHDIR/${_mod%.ko}.ko"
                    return $_ret
                fi

                if [[ $omit_drivers ]] && [[ "$1" =~ $omit_drivers ]]; then
                    dinfo "Omitting driver ${_mod##$srcmods}"
                    return 0
                fi

                # If we are building a host-specific initramfs and this
                # module is not already loaded, move on to the next one.
                [[ $hostonly ]] \
                    && ! module_is_host_only "$_mod" \
                    && return 0

                if [[ "$_check" = "yes" ]] || ! [[ $DRACUT_KERNEL_LAZY_HASHDIR ]]; then
                    # We use '-d' option in modprobe only if modules prefix path
                    # differs from default '/'.  This allows us to use dracut with
                    # old version of modprobe which doesn't have '-d' option.
                    local _moddirname=${srcmods%%/lib/modules/*}
                    [[ -n ${_moddirname} ]] && _moddirname="-d ${_moddirname}/"

                    # ok, load the module, all its dependencies, and any firmware
                    # it may require
                    for_each_kmod_dep install_kmod_with_fw $_mod \
                        --set-version $kernel ${_moddirname} $_mpargs
                    ((_ret+=$?))
                else
                    [[ $DRACUT_KERNEL_LAZY_HASHDIR ]] && \
                        echo $_mod >> "$DRACUT_KERNEL_LAZY_HASHDIR/lazylist"
                fi
                ;;
        esac
        return $_ret
    }

    function instmods_1() {
        local _mod _mpargs
        if (($# == 0)); then  # filenames from stdin
            while read _mod; do
                inst1mod "${_mod%.ko*}" || {
                    if [[ "$_check" == "yes" ]]; then
                        [[ "$_silent" == "no" ]] && dfatal "Failed to install module $_mod"
                        return 1
                    fi
                }
            done
        fi
        while (($# > 0)); do  # filenames as arguments
            inst1mod ${1%.ko*} || {
                if [[ "$_check" == "yes" ]]; then
                    [[ "$_silent" == "no" ]] && dfatal "Failed to install module $1"
                    return 1
                fi
            }
            shift
        done
        return 0
    }

    local _ret _filter_not_found='FATAL: Module .* not found.'
    # Capture all stderr from modprobe to _fderr. We could use {var}>...
    # redirections, but that would make dracut require bash4 at least.
    eval "( instmods_1 \"\$@\" ) ${_fderr}>&1" \
    | while read line; do [[ "$line" =~ $_filter_not_found ]] || echo $line;done | derror
    _ret=$?
    return $_ret
}
