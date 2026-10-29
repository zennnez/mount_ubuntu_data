#!/system/bin/sh
# late_start service: live description daemon + auto-mount after first unlock
# Author: zen
MODDIR=${0%/*}
LOG=/data/adb/mount_ubuntu_data/mount.log

# keep module.prop's description updated (single instance, exits if module is disabled)
nohup sh "$MODDIR/ubuntu-data.sh" daemon >>"$LOG" 2>&1 &

# wait for boot + first unlock (CE storage), then mount if AUTOMOUNT=1
(sh "$MODDIR/ubuntu-data.sh" boot-mount >>"$LOG" 2>&1) &
