#!/bin/sh

# We use (fcoe_interface or fcoe_mac) and fcoe_dcb as set by parse-fcoe.sh
# If neither mac nor interface are set we don't continue
[ -z "$fcoe_interface" -a -z "$fcoe_mac" ] && return

# Write udev rules
{
    if [ -n "$fcoe_mac" ] ; then
	printf 'ACTION=="add", SUBSYSTEM=="net", ATTR{address}=="%s", RUN+="/sbin/fcoe-up $env{INTERFACE} %s"\n' "$fcoe_mac" "$fcoe_dcb"
    else
	printf 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="%s", RUN+="/sbin/fcoe-up $env{INTERFACE} %s"\n' "$fcoe_interface" "$fcoe_dcb"
    fi
} > /etc/udev/rules.d/60-fcoe.rules