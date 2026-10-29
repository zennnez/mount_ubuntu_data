#!/bin/sh
# ==============================================================================
# setup-sharing.sh - run INSIDE Ubuntu, as root.   Author: zen
#
# Makes the shared partition usable from Android without root:
#   * creates group media_rw (gid 1023), the group Android's storage daemon runs in
#   * adds your Ubuntu user(s) to it
#   * share root becomes setgid media_rw, so new files inherit the group
#   * grants group media_rw rwX through POSIX ACLs on everything, plus a default ACL on
#     folders, so files created later (even by root, with a strict umask) stay accessible
# Files keep their owner and their 'other' permission bits. Other Ubuntu users and other
# Android apps get nothing new.
#
# Usage: sh setup-sharing.sh [-m MOUNTPOINT] [-u USER]... [-g GID] [--no-acl] [-f]
#   -f  allow a MOUNTPOINT that is not a separate mounted partition (normally refused)
#   default MOUNTPOINT: the partition this script was published on (its parent folder)
#   default users:      $SUDO_USER, else every normal user (uid 1000-59999)
# ==============================================================================
set -eu

GID=1023
USERS=""
ACL=1
FORCE=0
MP=""

# Auto-detect Ubuntu shared partition mountpoint (/media/data or /data)
for _cand in /media/data /data /mnt/data; do
  if grep -qs "[[:space:]]$_cand[[:space:]]" /proc/mounts; then
    MP="$_cand"
    break
  fi
done
[ -z "$MP" ] && [ -d /media/data ] && MP="/media/data"
[ -z "$MP" ] && MP="/data"

while [ $# -gt 0 ]; do
  case "$1" in
    -m) MP=$2; shift 2 ;;
    -u) USERS="$USERS $2"; shift 2 ;;
    -g) GID=$2; shift 2 ;;
    --no-acl) ACL=0; shift ;;
    -f) FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo sh $0)" >&2; exit 1; }
[ -d "$MP" ] || { echo "mountpoint $MP does not exist" >&2; exit 1; }

# STRICT SAFETY CHECK: NEVER modify system root or critical directories
case "$MP" in
  /|/root|/home|/etc|/usr|/var|/boot|/sys|/proc|/dev)
    echo "[!] CRITICAL ERROR: Refusing to modify system path '$MP'!" >&2
    echo "[!] Specify the shared data partition with -m (e.g. -m /media/data)" >&2
    exit 1
    ;;
esac

# The share must be its own mounted partition; a plain folder on the root filesystem is refused
is_mountpoint() {
  if command -v mountpoint >/dev/null 2>&1; then mountpoint -q "$1"
  else grep -qs "[[:space:]]$1[[:space:]]" /proc/mounts; fi
}
if [ "$FORCE" -ne 1 ] && ! is_mountpoint "$MP"; then
  echo "[!] $MP is not a mounted partition (is the shared partition mounted in Ubuntu?)." >&2
  echo "[!] Check with: findmnt | grep -E 'data|sd'   then pass it: sh $0 -m /path/to/mount  (or -f to force)" >&2
  exit 1
fi

case "$GID" in ""|*[!0-9]*) echo "bad gid" >&2; exit 2 ;; esac

# 1. group
GNAME=$(getent group "$GID" | cut -d: -f1 || true)
if [ -z "$GNAME" ]; then
  GNAME=media_rw
  groupadd -g "$GID" "$GNAME"
  echo "[+] created group $GNAME ($GID)"
else
  echo "[=] gid $GID is group '$GNAME'"
fi

# 2. users
if [ -z "$USERS" ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    USERS=$SUDO_USER
  else
    USERS=$(getent passwd | awk -F: '$3>=1000 && $3<60000 {print $1}')
  fi
fi
for u in $USERS; do
  if id "$u" >/dev/null 2>&1; then
    usermod -aG "$GNAME" "$u" && echo "[+] $u added to $GNAME (log out/in to apply)"
  else
    echo "[!] no such user: $u" >&2
  fi
done

# 3. share root group & permissions (owners and 'other' bits are left alone)
chgrp "$GNAME" "$MP" && chmod 2775 "$MP" || echo "[!] could not set group/mode on $MP" >&2
echo "[-] setting group $GNAME and g+rwX on existing files (can take a while on big trees)..."
find "$MP" -xdev -path "$MP/lost+found" -prune -o ! -type l -exec chgrp "$GNAME" {} + 2>/dev/null || true
find "$MP" -xdev -path "$MP/lost+found" -prune -o ! -type l -exec chmod g+rwX {} + 2>/dev/null || true
find "$MP" -xdev -path "$MP/lost+found" -prune -o -type d -exec chmod g+s {} + 2>/dev/null || true
TARGET_USER=$(echo "$USERS" | awk '{print $1}')
echo "[+] $MP is now group $GNAME, setgid, group rwX (owners unchanged)"

# 4. ACLs
if [ "$ACL" -eq 1 ]; then
  if ! command -v setfacl >/dev/null 2>&1; then
    echo "[~] setfacl missing, installing package 'acl'"
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y acl >/dev/null; else echo "[!] install 'acl' manually, then rerun" >&2; exit 1; fi
  fi
  echo "[-] applying ACLs (this can take a while on big trees)..."
  find "$MP" -xdev -path "$MP/lost+found" -prune -o ! -type l -exec setfacl -m "${TARGET_USER:+u:$TARGET_USER:rwX,}g:$GID:rwX,m::rwx" {} + 2>/dev/null || true
  find "$MP" -xdev -path "$MP/lost+found" -prune -o -type d -exec setfacl -m "${TARGET_USER:+d:u:$TARGET_USER:rwX,}d:g:$GID:rwX,d:m::rwx" {} + 2>/dev/null || true
  echo "[+] ACLs set: group $GID${TARGET_USER:+ and user $TARGET_USER} have rwX on existing files; new files inherit it"
fi

echo "[+] Done. Log out/in (or reboot Ubuntu) once so group membership applies; Android can read/write via /sdcard/<folder>."
