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
#   * tests the result as Android's media daemon (uid 10234, gid 1023) and says what is still blocked
#   * installs the command  share-fix  so you can repeat this quickly on one folder
# Files keep their owner and their 'other' permission bits. Other Ubuntu users and other
# Android apps get nothing new.
#
# WHY IT MUST BE REPEATED AFTER EXTRACTING ARCHIVES: an archive carries its own modes (often
# 0700 / 0600) and, extracted as root, tar also restores its owner and group. That bypasses the
# setgid group inheritance, and chmod to 0700 sets the ACL mask to "---", which switches off every
# ACL entry above. The folder then looks fine in Ubuntu but Android cannot open it. No tar/unzip
# option widens modes the archive stores, so run this afterwards on the extracted folder:
#   share-fix /data/<folder>
#
# Usage: sh setup-sharing.sh [-m MOUNTPOINT] [-p FOLDER | FOLDER] [-u USER]... [-g GID] [--no-acl] [--no-install] [-f]
#   -p FOLDER   only repair this folder (inside MOUNTPOINT); fast. A bare /path works too.
#   -f          allow a MOUNTPOINT that is not a separate mounted partition (normally refused)
#   default MOUNTPOINT: /media/data, /data or /mnt/data, whichever is a mounted partition
#   default users:      $SUDO_USER, else every normal user (uid 1000-59999)
# ==============================================================================
set -eu

GID=1023
USERS=""
ACL=1
FORCE=0
INSTALL=1
FIXPATH=""
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
    -p) FIXPATH=$2; shift 2 ;;
    -u) USERS="$USERS $2"; shift 2 ;;
    -g) GID=$2; shift 2 ;;
    --no-acl) ACL=0; shift ;;
    --no-install) INSTALL=0; shift ;;
    -f) FORCE=1; shift ;;
    -h|--help) sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    /*) FIXPATH=$1; shift ;;
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

# Scope: the whole share, or one folder inside it
SCOPE=$MP
if [ -n "$FIXPATH" ]; then
  SCOPE=$(readlink -f "$FIXPATH" 2>/dev/null || echo "$FIXPATH")
  case "$SCOPE" in
    "$MP"|"$MP"/*) ;;
    *) echo "[!] $FIXPATH is not inside $MP" >&2; exit 1 ;;
  esac
  [ -d "$SCOPE" ] || { echo "[!] $SCOPE is not a folder" >&2; exit 1; }
fi

ERR=$(mktemp)
trap 'rm -f "$ERR"' EXIT

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
TARGET_USER=$(echo "$USERS" | awk '{print $1}')

# 3. share root and every folder between it and the repaired folder: traversable by the group
chgrp "$GNAME" "$MP" && chmod 2775 "$MP" || echo "[!] could not set group/mode on $MP" >&2
if [ "$SCOPE" != "$MP" ]; then
  _acc=$MP
  _oldifs=$IFS; IFS=/; set -- ${SCOPE#"$MP"}; IFS=$_oldifs
  for _seg in "$@"; do
    [ -n "$_seg" ] || continue
    _acc=$_acc/$_seg
    [ "$_acc" = "$SCOPE" ] && break
    chgrp "$GNAME" "$_acc" 2>>"$ERR" && chmod g+rwx,g+s "$_acc" 2>>"$ERR" || true
  done
fi

# 4. group + permissions on everything below the scope (owners and 'other' bits are left alone)
echo "[-] setting group $GNAME and g+rwX on $SCOPE (can take a while on big trees)..."
find "$SCOPE" -xdev -path "$MP/lost+found" -prune -o ! -type l -exec chgrp "$GNAME" {} + 2>>"$ERR" || true
find "$SCOPE" -xdev -path "$MP/lost+found" -prune -o ! -type l -exec chmod g+rwX {} + 2>>"$ERR" || true
find "$SCOPE" -xdev -path "$MP/lost+found" -prune -o -type d -exec chmod g+s {} + 2>>"$ERR" || true
echo "[+] $SCOPE is now group $GNAME, setgid folders, group rwX (owners unchanged)"

# 5. ACLs (also repairs the ACL mask that tar -x as root sets to '---')
if [ "$ACL" -eq 1 ]; then
  if ! command -v setfacl >/dev/null 2>&1; then
    echo "[~] setfacl missing, installing package 'acl'"
    if command -v apt-get >/dev/null 2>&1; then apt-get install -y acl >/dev/null; else echo "[!] install 'acl' manually, then rerun" >&2; exit 1; fi
  fi
  echo "[-] applying ACLs (this can take a while on big trees)..."
  find "$SCOPE" -xdev -path "$MP/lost+found" -prune -o ! -type l -exec setfacl -m "${TARGET_USER:+u:$TARGET_USER:rwX,}g:$GID:rwX,m::rwx" {} + 2>>"$ERR" || true
  find "$SCOPE" -xdev -path "$MP/lost+found" -prune -o -type d -exec setfacl -m "${TARGET_USER:+d:u:$TARGET_USER:rwX,}d:g:$GID:rwX,d:m::rwx" {} + 2>>"$ERR" || true
  echo "[+] ACLs set: group $GID${TARGET_USER:+ and user $TARGET_USER} have rwX on existing files; new files inherit it"
fi

if [ -s "$ERR" ]; then
  echo "[~] some entries could not be changed (first lines):"
  sort -u "$ERR" | head -n 5
fi

# 6. test it the way Android's media daemon sees it (uid 10234, gid 1023, no other groups)
RC=0
if command -v setpriv >/dev/null 2>&1; then
  _chk() { setpriv --reuid 10234 --regid 1023 --clear-groups find "$SCOPE" -xdev "$@" -print 2>/dev/null; }
  _unread=$(_chk \( -type d \( ! -readable -o ! -executable \) \) -o \( -type f ! -readable \) | head -n 2000)
  _unwrite=$(_chk -type f ! -writable | head -n 2000)
  _n1=$(printf '%s' "$_unread" | grep -c . || true)
  _n2=$(printf '%s' "$_unwrite" | grep -c . || true)
  echo "[=] As the Android media daemon: $_n1 folder(s)/file(s) not readable, $_n2 file(s) not writable (first 2000 checked)"
  if [ "$_n1" -gt 0 ] || [ "$_n2" -gt 0 ]; then
    RC=1
    echo "[!] still blocked, for example:"
    printf '%s\n%s\n' "$_unread" "$_unwrite" | grep . | head -n 5 | while IFS= read -r _p; do ls -ldn "$_p"; done
    echo "[!] check these with:  ls -ldn <path>; getfacl <path>   (mask:: must not be '---')"
  fi
else
  echo "[~] setpriv not found, so the Android-side check was skipped"
fi

# 7. install the quick command
if [ "$INSTALL" -eq 1 ] && [ -d /usr/local/sbin ] && [ -w /usr/local/sbin ]; then
  _self=$(readlink -f "$0" 2>/dev/null || echo "$0")
  if [ -f "$_self" ] && [ "$_self" != /usr/local/sbin/share-fix ]; then
    cp "$_self" /usr/local/sbin/share-fix 2>/dev/null && chmod 755 /usr/local/sbin/share-fix \
      && echo "[+] installed: share-fix  (run  share-fix /path/to/folder  after extracting or copying files as root)"
  fi
fi

echo "[+] Done. Log out/in (or reboot Ubuntu) once so group membership applies; Android can read/write via /sdcard/<folder>."
echo "[i] After extracting an archive or copying files as root, run:  share-fix /data/<folder>   (archives keep their own private modes)"
exit $RC
