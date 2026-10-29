#!/system/bin/sh
# Author: zen
MODDIR=${0%/*}
sh "$MODDIR/ubuntu-data.sh" umount force >/dev/null 2>&1
rm -rf /data/adb/mount_ubuntu_data
