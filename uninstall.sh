#!/system/bin/sh
# Author: zen
MODDIR=${0%/*}
sh "$MODDIR/ubuntu-data.sh" umount force >/dev/null 2>&1
sm set-virtual-disk false >/dev/null 2>&1
rm -f /data/misc/vold/virtual_disk
rm -rf /data/adb/mount_ubuntu_data
