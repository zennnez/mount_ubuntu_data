#!/system/bin/sh
# Action button in KernelSU/Magisk manager: toggles the mount and prints status
# Author: zen
MODDIR=${0%/*}
sh "$MODDIR/ubuntu-data.sh" toggle
echo
sh "$MODDIR/ubuntu-data.sh" info
