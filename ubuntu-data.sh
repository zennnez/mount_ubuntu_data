#!/system/bin/sh
# ==============================================================================
# ubuntu-data.sh - mount / umount / status helper for "Mount Ubuntu Data"
# Author: zen
#
# Usage: ubuntu-data.sh <command> [args]
#   status            key=value status dump (used by the WebUI)
#   info              human readable status
#   mount             mount the partition (idempotent)
#   umount [force]    unmount (force = lazy detach if busy)
#   toggle            mount if unmounted, umount if mounted
#   set KEY VALUE     change AUTOMOUNT / FIX_ROOT_PERMS / DISABLE_DATA_MOUNT /
#                     AUTOFIX_PERMS / MOUNT_MODE / MOUNT_NAME in config.sh
#   partition get|test <name>|set <name> [force]
#                     partition = /dev/block/by-name/<name> (default "data")
#   format ext4|exfat format the shared partition with a clean filesystem
#   browse <dir>      list sub-folders of an absolute path (WebUI folder picker)
#   mkdir <dir>       create a folder inside the partition or internal storage
#   bind list|add|edit|del|mount|umount|test|fixwrite   folder mounts (binds.conf)
#   packages [filter] list installed apps for app folder picker
#   layout            show which block device the partition name resolves to
#   access            test what the Android media daemon (gid media_rw) can read/write
#   fixperms read|rw [folder]
#                     fix permissions for Android media_rw
#   fsck              e2fsck -p on the (unmounted) partition
#   restart-media     force-stop MediaProvider so /sdcard re-reads the mount
#   fixview           restart MediaProvider and wait until apps see storage
#   diag              diagnostics dump
#   log [N]           last N log lines (default 60)
#   log-export        save full log to /sdcard/Download/
#   boot-mount        used by service.sh (waits for unlock, then mounts)
#   daemon            keeps the module.prop description up to date
#   init-config       create config.sh if missing
# ==============================================================================

export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH

MODID=mount_ubuntu_data
case "$0" in
  */*) _d=${0%/*} ;;
  *)   _d=. ;;
esac
MODDIR=$(cd "$_d" 2>/dev/null && pwd)

DATA_DIR=${UD_DATA:-/data/adb/$MODID}
CONF=$DATA_DIR/config.sh
LOG=$DATA_DIR/mount.log
BINDS=$DATA_DIR/binds
ERRF=$DATA_DIR/last_error
LOCKDIR=$DATA_DIR/.lock
PIDFILE=$DATA_DIR/daemon.pid
SD_BASE=${UD_SD:-/data/media/0}
SYSBLK=${UD_SYSBLK:-/sys/class/block}
DEVBLK=${UD_DEVBLK:-/dev/block}
STAGING_DIR=/mnt/local_ubuntu_data
VOLD_STUB=/data/misc/vold/virtual_disk

mkdir -p "$DATA_DIR" 2>/dev/null
NICE_CMD=""
command -v nice >/dev/null 2>&1 && NICE_CMD="nice -n 19"
chmod 0700 "$DATA_DIR" 2>/dev/null

# ------------------------------------------------------------------------------
# Mount namespace: re-run inside init's (pid 1) namespace so all apps see mounts
# ------------------------------------------------------------------------------
find_nsenter() {
  NSE=""
  if command -v nsenter >/dev/null 2>&1; then NSE=nsenter; return 0; fi
  for _b in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
    if [ -x "$_b" ] && "$_b" nsenter --help >/dev/null 2>&1; then NSE="$_b nsenter"; return 0; fi
  done
  return 1
}

ensure_init_ns() {
  [ -n "$UD_NS" ] && return 0
  [ -r /proc/1/ns/mnt ] || return 0
  [ "$(readlink /proc/self/ns/mnt 2>/dev/null)" = "$(readlink /proc/1/ns/mnt 2>/dev/null)" ] && return 0
  if ! find_nsenter; then
    _log "WARNING: running in a private mount namespace and no nsenter found"
    return 0
  fi
  # shellcheck disable=SC2086
  if ! $NSE -t 1 -m -- true >/dev/null 2>&1; then
    _log "WARNING: nsenter into init's mount namespace failed"
    return 0
  fi
  UD_NS=1; export UD_NS
  # shellcheck disable=SC2086
  exec $NSE -t 1 -m -- sh "$MODDIR/ubuntu-data.sh" "$@"
}

# ------------------------------------------------------------------------------
# Config
# ------------------------------------------------------------------------------
valid_partname() {
  case "$1" in
    ""|.|..|-*|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  [ "${#1}" -le 36 ]
}

resolve_dev() {
  LAYOUT=""
  if [ "$DEV_CFG" = "auto" ]; then
    DEV=""
    for _bn in "$DEVBLK/by-name/$PART_NAME" "$DEVBLK/bootdevice/by-name/$PART_NAME"; do
      if [ -e "$_bn" ]; then DEV=$_bn; break; fi
    done
    [ -n "$DEV" ] || DEV=$DEVBLK/by-name/$PART_NAME
  else
    DEV=$DEV_CFG
  fi
  DEV_REAL=$(readlink -f "$DEV" 2>/dev/null)
  [ -z "$DEV_REAL" ] && DEV_REAL=$DEV
  DEV_BASE=${DEV_REAL##*/}
  DEV_MM=$(cat "$SYSBLK/$DEV_BASE/dev" 2>/dev/null)
  DEV_PARTNAME=$(sed -n 's/^PARTNAME=//p' "$SYSBLK/$DEV_BASE/uevent" 2>/dev/null)
  [ "$DEV_CFG" = "auto" ] && LAYOUT="by-name/$PART_NAME -> $DEV_REAL"
}

use_partname() {
  PART_NAME=$1
  DEV_CFG=auto
  resolve_dev
}

load_conf() {
  DEV=auto
  PART_NAME=data
  MOUNT_MODE=sdcard
  MOUNT_NAME=ubuntu
  AUTOMOUNT=0
  FIX_ROOT_PERMS=1
  DISABLE_DATA_MOUNT=0
  AUTOFIX_PERMS=0
  EXTRA_BINDS=""
  PUBLISH_TOOLS=1
  PARTNAME_DENY="userdata metadata persist* cache misc frp keystore devinfo oplusreserve* oem* modem* super boot* init_boot* vendor_boot* dtbo* vbmeta* recovery*"
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"

  case "$MOUNT_MODE" in
    sdcard|internal) ;;
    *) MOUNT_MODE=sdcard ;;
  esac
  case "$MOUNT_NAME" in
    ""|.|..|*/*|*" "*) MOUNT_NAME=ubuntu ;;
  esac
  valid_partname "$PART_NAME" || PART_NAME=data
  [ -n "$DEV" ] || DEV=auto
  [ "$DISABLE_DATA_MOUNT" = "1" ] || DISABLE_DATA_MOUNT=0
  [ "$AUTOFIX_PERMS" = "1" ] || AUTOFIX_PERMS=0

  SD_UUID=$(sm list-volumes public 2>/dev/null | sed -n 's/.*mounted \([0-9A-Fa-f-]*\).*/\1/p' | head -n 1)
  if [ -z "$SD_UUID" ] && [ -f "$DATA_DIR/sd_uuid" ]; then
    SD_UUID=$(head -n 1 "$DATA_DIR/sd_uuid" 2>/dev/null)
  fi

  if [ "$MOUNT_MODE" = "sdcard" ]; then
    TARGET=$STAGING_DIR
    if [ -n "$SD_UUID" ]; then
      SDPATH=/storage/$SD_UUID
    else
      SDPATH="SD Card"
    fi
  else
    TARGET=$SD_BASE/$MOUNT_NAME
    SDPATH=/sdcard/$MOUNT_NAME
  fi

  DEV_CFG=$DEV
  resolve_dev
  _lc="DEV_CFG=$DEV_CFG DEV_REAL=$DEV_REAL PARTNAME=$DEV_PARTNAME layout=$LAYOUT MODE=$MOUNT_MODE NAME=$MOUNT_NAME UUID=$SD_UUID"
  if [ "$_lc" != "$(cat "$DATA_DIR/.lastconf" 2>/dev/null)" ]; then
    _log "load_conf: $_lc"
    echo "$_lc" > "$DATA_DIR/.lastconf" 2>/dev/null
  fi
}

conf_put() {
  cmd_init_config
  grep -v "^$1=" "$CONF" > "$CONF.tmp" 2>/dev/null
  echo "$1=$2" >> "$CONF.tmp"
  cat "$CONF.tmp" > "$CONF"
  rm -f "$CONF.tmp"
}

cmd_init_config() {
  if [ -f "$CONF" ]; then
    grep -q '^PART_NAME=' "$CONF" 2>/dev/null || printf '\nPART_NAME=data\n' >> "$CONF"
    grep -q '^MOUNT_MODE=' "$CONF" 2>/dev/null || printf '\nMOUNT_MODE=sdcard\n' >> "$CONF"
    grep -q '^MOUNT_NAME=' "$CONF" 2>/dev/null || printf '\nMOUNT_NAME=ubuntu\n' >> "$CONF"
    grep -q '^AUTOFIX_PERMS=' "$CONF" 2>/dev/null || printf '\nAUTOFIX_PERMS=0\n' >> "$CONF"
    return 0
  fi
  cat > "$CONF" <<'EOF'
# Mount Ubuntu Data - configuration (sourced as shell). Author: zen
# Mount mode: "sdcard" (default: native external SD Card in Android) or "internal" (/sdcard/<MOUNT_NAME>)
MOUNT_MODE=sdcard
# Block device of the shared partition. "auto" = /dev/block/by-name/<PART_NAME>.
DEV=auto
# Partition name under /dev/block/by-name/ (changeable in the WebUI)
PART_NAME=data
# Folder name in Android internal storage when using "internal" mode: /sdcard/<MOUNT_NAME>
MOUNT_NAME=ubuntu
# 1 = mount automatically after boot (once unlocked). Default 0 = off.
AUTOMOUNT=0
# 1 = chown the partition root to media_rw (1023) with setgid so Android apps can write
FIX_ROOT_PERMS=1
# 1 = never mount the shared partition (dual-boot option)
DISABLE_DATA_MOUNT=0
# 1 = once after mount, fix permissions for files Android cannot use
AUTOFIX_PERMS=0
# Extra bind mounts: "source:destination"
EXTRA_BINDS=""
# 1 = copy ubuntu/setup-sharing.sh onto the partition (/.ubuntu-data-tools/)
PUBLISH_TOOLS=1
EOF
  chmod 0600 "$CONF"
}

# ------------------------------------------------------------------------------
# Logging / errors / locking
# ------------------------------------------------------------------------------
_log() { echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null; }
say() { echo "$*"; _log "$*"; }
trim_log() {
  [ -f "$LOG" ] || return 0
  _sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if [ "$_sz" -gt 204800 ]; then
    tail -n 300 "$LOG" > "$LOG.tmp" 2>/dev/null && cat "$LOG.tmp" > "$LOG"
    rm -f "$LOG.tmp"
  fi
}
set_err() { echo "$*" > "$ERRF" 2>/dev/null; _log "ERROR: $*"; }
clr_err() { rm -f "$ERRF" 2>/dev/null; }

lock() {
  _i=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    _p=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [ -n "$_p" ] && ! kill -0 "$_p" 2>/dev/null; then
      rm -rf "$LOCKDIR"
      continue
    fi
    _i=$((_i + 1))
    if [ -z "$_p" ] && [ "$_i" -ge 5 ]; then
      rm -rf "$LOCKDIR"
      continue
    fi
    if [ "$_i" -ge 60 ]; then
      echo "Another mount/umount operation is still running."
      return 1
    fi
    sleep 1
  done
  echo $$ > "$LOCKDIR/pid"
  trap 'rm -rf "$LOCKDIR"' EXIT
  return 0
}
unlock() { rm -rf "$LOCKDIR"; }

# ------------------------------------------------------------------------------
# Mount table helpers
# ------------------------------------------------------------------------------
mnt_find() {
  MI_MM=""; MI_FS=""; MI_OPTS=""; MI_SUPER=""
  _found=1
  while read -r _id _par _mm _root _mp _opts _rest; do
    if [ "$_mp" = "$1" ]; then
      MI_MM=$_mm
      MI_OPTS=$_opts
      _after=" $_rest"
      _after=${_after#* - }
      MI_FS=${_after%% *}
      _r2=${_after#* }
      MI_SUPER=${_r2#* }
      _found=0
    fi
  done < /proc/self/mountinfo
  return $_found
}

dev_in_use() {
  [ -n "$DEV_MM" ] || return 1
  while read -r _id _par _mm _rest; do
    [ "$_mm" = "$DEV_MM" ] && return 0
  done < /proc/self/mountinfo
  return 1
}

is_sdcard_mounted() {
  mnt_find "$STAGING_DIR" && [ -n "$DEV_MM" ] && [ "$MI_MM" = "$DEV_MM" ] && [ -n "$SD_UUID" ] && [ -d "/storage/$SD_UUID" ]
}

is_internal_mounted() {
  mnt_find "$SD_BASE/$MOUNT_NAME" && [ -n "$DEV_MM" ] && [ "$MI_MM" = "$DEV_MM" ]
}

mounted_ours() {
  is_sdcard_mounted || is_internal_mounted
}

ce_ready() {
  [ "$(getprop sys.boot_completed)" = "1" ] || return 1
  [ "$(getprop sys.user.0.ce_available)" = "true" ] && [ -d "$SD_BASE" ] && return 0
  [ -d "$SD_BASE/Android" ]
}

# ------------------------------------------------------------------------------
# Superblock probing
# ------------------------------------------------------------------------------
rd() {
  dd if="$DEV_REAL" bs="$1" skip="$2" count=1 2>/dev/null | od -An -v -tx1 | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'
}

preflight() {
  PF_MSG=""
  PF_WARN=""
  DEV_FS=""
  if [ ! -b "$DEV_REAL" ]; then
    if [ "$DEV_CFG" = "auto" ]; then
      PF_MSG="partition '$PART_NAME' not found ($DEVBLK/by-name/$PART_NAME does not exist)"
    else
      PF_MSG="$DEV not found (partition does not exist on this device)"
    fi
    return 10
  fi

  for _pat in $PARTNAME_DENY; do
    # shellcheck disable=SC2254
    case "$DEV_PARTNAME" in
      $_pat) PF_MSG="refusing: $DEV is partition '$DEV_PARTNAME', a protected system partition"; return 11 ;;
    esac
  done

  if mnt_find /data && [ -n "$DEV_MM" ] && [ "$MI_MM" = "$DEV_MM" ]; then
    PF_MSG="refusing: $DEV is Android's own /data"
    return 11
  fi

  if [ "$(rd 6 0)" = "4c 55 4b 53 ba be" ]; then
    PF_MSG="$DEV has a LUKS header (encrypted); not mounting"
    return 12
  fi

  _ext4magic=$(rd 2 540)
  _exfatmagic=$(dd if="$DEV_REAL" bs=1 skip=3 count=8 2>/dev/null)
  _log "preflight: DEV=$DEV_REAL ext4magic=$_ext4magic exfatmagic=$_exfatmagic f2fs=$(rd 4 256)"

  if [ "$_ext4magic" = "53 ef" ]; then
    DEV_FS=ext4
  elif [ "$_exfatmagic" = "EXFAT   " ]; then
    DEV_FS=exfat
  elif command -v blkid >/dev/null 2>&1 && blkid "$DEV_REAL" 2>/dev/null | grep -q 'TYPE="exfat"'; then
    DEV_FS=exfat
  else
    if [ "$(rd 4 256)" = "10 20 f5 f2" ]; then
      PF_MSG="$DEV is f2fs, not ext4/exfat (format it: mkfs.ext4 $DEV)"
    else
      PF_MSG="$DEV has no ext4 or exfat filesystem; magic=$_ext4magic"
    fi
    return 12
  fi

  if [ "$DEV_FS" = "ext4" ]; then
    set -- $(rd 4 280)
    if [ -n "$3" ] && [ $(( 0x$3 & 1 )) -ne 0 ]; then
      PF_WARN="ext4 'encrypt' feature flag is set; fscrypt folders will look scrambled without their key"
    fi
  fi
  return 0
}

# ------------------------------------------------------------------------------
# Status
# ------------------------------------------------------------------------------
fmt_kb() {
  _k=$1
  if [ "$_k" -ge 1048576 ]; then
    echo "$((_k / 1048576)).$(( (_k % 1048576) * 10 / 1048576 ))G"
  elif [ "$_k" -ge 1024 ]; then
    echo "$((_k / 1024)).$(( (_k % 1024) * 10 / 1024 ))M"
  else
    echo "${_k}K"
  fi
}

android_view() {
  if [ "$MOUNT_MODE" = "sdcard" ]; then
    [ -n "$SD_UUID" ] && [ -d "/storage/$SD_UUID" ] && { echo ok; return; }
    echo missing
    return
  fi
  for _root in /storage/emulated/0 /mnt/user/0/emulated/0; do
    if [ -d "$_root/Android" ]; then
      [ -d "$_root/$MOUNT_NAME" ] || { echo missing; return; }
      _a=$(ls -A "$TARGET" 2>/dev/null | head -n 20)
      _b=$(ls -A "$_root/$MOUNT_NAME" 2>/dev/null | head -n 20)
      if [ "$_a" = "$_b" ]; then echo ok; else echo missing; fi
      return
    fi
  done
  echo n/a
}

compute_status() {
  S_STATE=""; S_FS=""; S_RW=""; S_VIEW="n/a"; S_SEL=""
  S_SIZE=0; S_USED=0; S_AVAIL=0; S_PCT=0; S_BINDS=0; S_ERR=""
  [ -s "$ERRF" ] && S_ERR=$(head -n 1 "$ERRF")
  [ -f "$BINDS" ] && S_BINDS=$(grep -c . "$BINDS" 2>/dev/null)
  entries_count

  if is_sdcard_mounted; then
    S_STATE=mounted
    S_FS=$DEV_FS; [ -z "$S_FS" ] && S_FS=$MI_FS
    case ",$MI_OPTS," in *,ro,*) S_RW=ro ;; *) S_RW=rw ;; esac
    set -- $(df -k "$STAGING_DIR" 2>/dev/null | tail -n 1)
    if [ -n "$2" ]; then
      S_SIZE=$2; S_USED=$3; S_AVAIL=$4; S_PCT=${5%\%}
    fi
    S_SEL="sdcard"
    S_VIEW=$(android_view)
  elif is_internal_mounted; then
    S_STATE=mounted
    S_FS=$MI_FS
    case ",$MI_OPTS," in *,ro,*) S_RW=ro ;; *) S_RW=rw ;; esac
    set -- $(df -k "$TARGET" 2>/dev/null | tail -n 1)
    if [ -n "$2" ]; then
      S_SIZE=$2; S_USED=$3; S_AVAIL=$4; S_PCT=${5%\%}
    fi
    S_SEL=$(cat "$DATA_DIR/mount_mode" 2>/dev/null)
    [ -n "$S_SEL" ] || S_SEL=unknown
    S_VIEW=$(android_view)
  elif [ "$DISABLE_DATA_MOUNT" = "1" ]; then
    S_STATE=disabled
  elif [ ! -b "$DEV_REAL" ]; then
    S_STATE=absent
  elif ! ce_ready; then
    S_STATE=waiting
  elif [ -n "$S_ERR" ]; then
    S_STATE=error
  else
    S_STATE=unmounted
  fi
}

build_summary() {
  _dn=${DEV_REAL##*/}
  case "$S_STATE" in
    mounted)
      if [ "$MOUNT_MODE" = "sdcard" ]; then
        S_SUMMARY="🟢 Mounted · $_dn ${S_FS:-ext4} ${S_RW} → SD Card ($SDPATH) · $(fmt_kb "$S_USED") of $(fmt_kb "$S_SIZE") used (${S_PCT}%)"
      else
        S_SUMMARY="🟢 Mounted · $_dn ${S_FS:-ext4} ${S_RW} → $SDPATH · $(fmt_kb "$S_USED") of $(fmt_kb "$S_SIZE") used (${S_PCT}%)"
      fi
      [ "$S_BINDS" -gt 0 ] && S_SUMMARY="$S_SUMMARY · $S_BINDS bind mount(s)"
      [ "$S_VIEW" = "missing" ] && S_SUMMARY="$S_SUMMARY · ⚠ not yet visible in Android"
      [ "$S_ENT_TOTAL" -gt 0 ] && S_SUMMARY="$S_SUMMARY · folders $S_ENT_MOUNTED/$S_ENT_TOTAL"
      ;;
    disabled)  S_SUMMARY="⚫ Partition mount disabled (dual-boot option) · nothing to mount" ;;
    unmounted) S_SUMMARY="🔴 Unmounted · $_dn is ready (press Action or use the WebUI to mount)" ;;
    waiting)   S_SUMMARY="⏳ Waiting for the first unlock to mount $_dn" ;;
    absent)
      if [ "$DEV_CFG" = "auto" ]; then S_SUMMARY="⚪ Partition '$PART_NAME' not found · nothing to mount"
      else S_SUMMARY="⚪ $DEV not found · nothing to mount"; fi ;;
    conflict)  S_SUMMARY="🟠 $S_ERR" ;;
    error)     S_SUMMARY="🟠 Mount failed · $S_ERR" ;;
    *)         S_SUMMARY="❔ Unknown state" ;;
  esac
}

cmd_status() {
  compute_status
  build_summary
  echo "state=$S_STATE"
  echo "device=$DEV_REAL"
  echo "partname=$DEV_PARTNAME"
  echo "dev_cfg=$DEV_CFG"
  echo "part_name=$PART_NAME"
  echo "mount_mode=$MOUNT_MODE"
  echo "mount_name=$MOUNT_NAME"
  echo "sd_uuid=$SD_UUID"
  echo "layout=$LAYOUT"
  echo "selabel=$S_SEL"
  echo "fstype=$S_FS"
  echo "mode=$S_RW"
  echo "mountpoint=$TARGET"
  echo "sdcard_path=$SDPATH"
  echo "size_kb=$S_SIZE"
  echo "used_kb=$S_USED"
  echo "avail_kb=$S_AVAIL"
  echo "use_pct=$S_PCT"
  echo "android_view=$S_VIEW"
  echo "binds=$S_BINDS"
  echo "entries_total=$S_ENT_TOTAL"
  echo "entries_mounted=$S_ENT_MOUNTED"
  echo "automount=$AUTOMOUNT"
  echo "fix_root_perms=$FIX_ROOT_PERMS"
  echo "disable_data_mount=$DISABLE_DATA_MOUNT"
  echo "autofix_perms=$AUTOFIX_PERMS"
  echo "autofix_last=$(cat "$DATA_DIR/autofix.last" 2>/dev/null)"
  echo "last_error=$S_ERR"
  echo "summary=$S_SUMMARY"
}

cmd_info() {
  compute_status
  build_summary
  echo "$S_SUMMARY"
  echo "mode        : $MOUNT_MODE"
  echo "device      : $DEV_REAL (${DEV_PARTNAME:-no partname})"
  echo "mountpoint  : $TARGET  (Android: $SDPATH)"
  echo "automount   : $AUTOMOUNT"
  echo "mount off   : $DISABLE_DATA_MOUNT (1 = partition mount disabled)"
  echo "android view: $S_VIEW"
  [ -n "$S_ERR" ] && echo "last error  : $S_ERR"
  return 0
}

# ------------------------------------------------------------------------------
# Mount helpers
# ------------------------------------------------------------------------------
mount_extra_binds() {
  [ -n "$EXTRA_BINDS" ] || return 0
  for _pair in $EXTRA_BINDS; do
    _src=${_pair%%:*}
    _dst=${_pair#*:}
    [ "$_src" = "@" ] && _src=$TARGET
    if [ -z "$_src" ] || [ -z "$_dst" ] || [ "$_src" = "$_pair" ]; then
      _log "bad EXTRA_BINDS entry: $_pair"
      continue
    fi
    mkdir -p "$_dst" 2>/dev/null
    if mnt_find "$_dst" && [ "$MI_MM" = "$DEV_MM" ]; then
      _log "bind already present: $_dst"
      continue
    fi
    if _e=$(mount --bind "$_src" "$_dst" 2>&1); then
      echo "$_dst" >> "$BINDS"
      say "[+] bind $_src -> $_dst"
    else
      say "[!] bind $_src -> $_dst failed: $_e"
    fi
  done
}

mount_runtime_views() {
  [ "$MOUNT_MODE" = "internal" ] || return 0
  for _base in /storage/emulated/0 /mnt/user/0/emulated/0 \
               /mnt/pass_through/0/emulated/0 /mnt/androidwritable/0/emulated/0 \
               /mnt/runtime/default/emulated/0 /mnt/runtime/read/emulated/0 /mnt/runtime/write/emulated/0; do
    [ -d "$_base" ] || continue
    _v=$_base/$MOUNT_NAME
    _sv=$(stat -c %d "$_v" 2>/dev/null)
    _st=$(stat -c %d "$TARGET" 2>/dev/null)
    [ -n "$_sv" ] && [ "$_sv" = "$_st" ] && continue
    mkdir -p "$_v" 2>/dev/null
    if mount --bind "$TARGET" "$_v" 2>/dev/null; then
      echo "$_v" >> "$BINDS"
      _log "bound into view $_v"
    fi
  done
}

publish_tools() {
  [ "$PUBLISH_TOOLS" = "1" ] || return 0
  _ps=$MODDIR/ubuntu/setup-sharing.sh
  [ -f "$_ps" ] || return 0
  _pd=$TARGET/.ubuntu-data-tools
  mkdir -p "$_pd" 2>/dev/null
  if ! cmp -s "$_ps" "$_pd/setup-sharing.sh" 2>/dev/null; then
    cp "$_ps" "$_pd/setup-sharing.sh" 2>/dev/null && chmod 755 "$_pd/setup-sharing.sh" && _log "published Ubuntu helper to $_pd"
  fi
}

apply_sepolicy() {
  _r="$MODDIR/sepolicy.rule"
  [ -f "$_r" ] || return 0
  if [ -x /data/adb/ksu/bin/ksud ]; then
    /data/adb/ksu/bin/ksud sepolicy apply "$_r" >/dev/null 2>&1
  elif command -v magiskpolicy >/dev/null 2>&1; then
    magiskpolicy --live --apply "$_r" >/dev/null 2>&1
  elif command -v supolicy >/dev/null 2>&1; then
    supolicy --live --apply "$_r" >/dev/null 2>&1
  fi
}

# ------------------------------------------------------------------------------
# Mount execution
# ------------------------------------------------------------------------------
do_mount() {
  load_conf
  apply_sepolicy
  if mounted_ours; then
    say "[=] Already mounted at $SDPATH"
    return 0
  fi
  if [ "$DISABLE_DATA_MOUNT" = "1" ]; then
    say "[=] Partition mount is disabled (DISABLE_DATA_MOUNT=1, dual-boot option). Switch it off in the WebUI to mount."
    return 14
  fi

  preflight
  _rc=$?
  if [ $_rc -ne 0 ]; then
    if [ $_rc -eq 10 ]; then
      say "[=] $PF_MSG"
      clr_err
      return 4
    fi
    set_err "$PF_MSG"
    say "[!] $PF_MSG"
    return $_rc
  fi
  [ -n "$PF_WARN" ] && say "[~] $PF_WARN"

  if ! ce_ready; then
    say "[!] Device not unlocked yet (credential-encrypted storage is locked); try again after unlocking."
    return 13
  fi

  if [ "$MOUNT_MODE" = "sdcard" ]; then
    # Unmount internal mode if active
    if mnt_find "$SD_BASE/$MOUNT_NAME"; then
      umount_one "$SD_BASE/$MOUNT_NAME" 1
    fi

    mkdir -p "$STAGING_DIR" 2>/dev/null
    say "[-] Preparing virtual SD card for $DEV_REAL ($DEV_FS) ..."

    # 1. Ensure vold stub file matches partition capacity
    _dev_sz=$(blockdev --getsize64 "$DEV_REAL" 2>/dev/null)
    [ -z "$_dev_sz" ] && _dev_sz=$(awk '{print $1*512}' "/sys/class/block/$DEV_BASE/size" 2>/dev/null)
    [ -z "$_dev_sz" ] && _dev_sz=323372560384
    _stub_sz=$(stat -c %s "$VOLD_STUB" 2>/dev/null || echo 0)
    if [ ! -f "$VOLD_STUB" ] || [ "$_stub_sz" != "$_dev_sz" ]; then
      say "[-] Initializing exFAT stub disk (${_dev_sz} bytes)..."
      sm set-virtual-disk false >/dev/null 2>&1
      truncate -s "$_dev_sz" "$VOLD_STUB" 2>/dev/null || truncate -s 256G "$VOLD_STUB"
      mkfs.exfat -L SDCARD "$VOLD_STUB" >/dev/null 2>&1
    fi

    # 2. Trigger vold virtual disk
    sm set-virtual-disk true >/dev/null 2>&1
    _uuid=""
    _w=0
    while [ $_w -lt 15 ]; do
      _vols=$(sm list-volumes public 2>/dev/null)
      case "$_vols" in
        *mounted*)
          _uuid=$(echo "$_vols" | sed -n 's/.*mounted \([0-9A-Fa-f-]*\).*/\1/p' | head -n 1)
          [ -n "$_uuid" ] && break
          ;;
        *unmounted*)
          _vol=$(echo "$_vols" | awk '{print $1}')
          [ -n "$_vol" ] && sm mount "$_vol" >/dev/null 2>&1
          ;;
      esac
      sleep 1
      _w=$((_w + 1))
    done

    if [ -z "$_uuid" ]; then
      set_err "Virtual SD card failed to mount in vold"
      say "[!] Virtual SD card failed to mount in vold"
      return 3
    fi
    echo "$_uuid" > "$DATA_DIR/sd_uuid"
    SD_UUID=$_uuid
    SDPATH=/storage/$SD_UUID

    # 3. Mount partition onto STAGING_DIR
    _lbl=u:object_r:media_rw_data_file:s0
    if [ "$DEV_FS" = "ext4" ]; then
      _mopts="rw,noatime,nosuid,nodev,context=$_lbl"
      if ! _merr=$(mount -t ext4 -o "$_mopts" "$DEV_REAL" "$STAGING_DIR" 2>&1); then
        _mopts="rw,noatime,nosuid,nodev"
        mount -t ext4 -o "$_mopts" "$DEV_REAL" "$STAGING_DIR" || {
          set_err "staging mount failed: $_merr"
          say "[!] Mount failed: $_merr"
          return 3
        }
      fi
    else
      _mopts="rw,noatime,uid=1023,gid=1023,fmask=0007,dmask=0007,context=$_lbl"
      if ! _merr=$(mount -t exfat -o "$_mopts" "$DEV_REAL" "$STAGING_DIR" 2>&1); then
        _mopts="rw,noatime,uid=1023,gid=1023,fmask=0007,dmask=0007"
        mount -t exfat -o "$_mopts" "$DEV_REAL" "$STAGING_DIR" || {
          set_err "staging exfat mount failed: $_merr"
          say "[!] Mount failed: $_merr"
          return 3
        }
      fi
    fi

    # 4. Bind mount over lower paths of vold
    mount --bind "$STAGING_DIR" "/mnt/media_rw/$SD_UUID" 2>/dev/null
    mount --bind "$STAGING_DIR" "/mnt/pass_through/0/$SD_UUID" 2>/dev/null
    echo "/mnt/pass_through/0/$SD_UUID" >> "$BINDS"
    echo "/mnt/media_rw/$SD_UUID" >> "$BINDS"

    # Set root permissions
    chown 1023:1023 "$STAGING_DIR" 2>/dev/null
    chmod 2777 "$STAGING_DIR" 2>/dev/null

    publish_tools
    clr_err
    say "[+] SUCCESS: $DEV_REAL ($DEV_FS) mounted as SD Card at $SDPATH"
    bind_mount_auto
    compute_status
    build_summary
    write_desc "$S_SUMMARY"
    return 0

  else
    # INTERNAL MODE: /sdcard/<MOUNT_NAME>
    if [ -n "$SD_UUID" ]; then
      umount_one "/mnt/pass_through/0/$SD_UUID" 1
      umount_one "/mnt/media_rw/$SD_UUID" 1
      sm set-virtual-disk false >/dev/null 2>&1
      rm -f "$DATA_DIR/sd_uuid"
      SD_UUID=""
    fi
    umount_one "$STAGING_DIR" 1

    mkdir -p "$TARGET" 2>/dev/null
    if [ ! -d "$TARGET" ]; then
      set_err "cannot create $TARGET"
      say "[!] cannot create $TARGET"
      return 3
    fi

    say "[-] Mounting $DEV_REAL on $TARGET ..."
    _ok=0; _err=""; _lbl=u:object_r:media_rw_data_file:s0; _mode=""
    for _try in ctx fsctx plain; do
      case "$_try" in
        ctx)   _opts="rw,noatime,nosuid,nodev,context=$_lbl" ;;
        fsctx) _opts="rw,noatime,nosuid,nodev,fscontext=$_lbl,defcontext=$_lbl" ;;
        plain) _opts="rw,noatime,nosuid,nodev" ;;
      esac
      if [ "$DEV_FS" = "exfat" ]; then
        _opts="rw,noatime,uid=1023,gid=1023,fmask=0007,dmask=0007,context=$_lbl"
        if _err=$(mount -t exfat -o "$_opts" "$DEV_REAL" "$TARGET" 2>&1); then
          _ok=1; _mode="exfat"; break
        fi
      else
        if _err=$(mount -t ext4 -o "$_opts" "$DEV_REAL" "$TARGET" 2>&1); then
          _ok=1; _mode=$_try; break
        fi
      fi
    done
    if [ $_ok -ne 1 ]; then
      set_err "mount failed: $_err"
      say "[!] Mount failed: $_err"
      return 3
    fi
    echo "$_mode" > "$DATA_DIR/mount_mode"

    if [ "$FIX_ROOT_PERMS" = "1" ]; then
      chown 1023:1023 "$TARGET" 2>/dev/null
      chmod 2777 "$TARGET" 2>/dev/null
    fi
    autofix_on_mount
    publish_tools
    : > "$BINDS"
    mount_runtime_views
    mount_extra_binds
    clr_err
    say "[+] SUCCESS: $DEV_REAL mounted at $TARGET (Android: $SDPATH)"
    bind_mount_auto
    ensure_android_view
    compute_status
    build_summary
    write_desc "$S_SUMMARY"
    return 0
  fi
}

# ------------------------------------------------------------------------------
# Umount
# ------------------------------------------------------------------------------
umount_one() {
  _n=0
  while mnt_find "$1" && [ $_n -lt 4 ]; do
    if umount "$1" 2>/dev/null; then
      _log "unmounted $1"
    elif [ "$2" = "1" ] && umount -l "$1" 2>/dev/null; then
      _log "lazy-unmounted $1"
    else
      return 1
    fi
    _n=$((_n + 1))
  done
  return 0
}

do_umount() {
  load_conf
  _force=$1
  stop_scan
  bind_umount_all "$_force"
  sync

  _uuid=$(cat "$DATA_DIR/sd_uuid" 2>/dev/null)
  [ -z "$_uuid" ] && _uuid=$(sm list-volumes public 2>/dev/null | sed -n 's/.*mounted \([0-9A-Fa-f-]*\).*/\1/p' | head -n 1)

  if [ -n "$_uuid" ]; then
    umount_one "/mnt/pass_through/0/$_uuid" "$_force"
    umount_one "/mnt/media_rw/$_uuid" "$_force"
    sm set-virtual-disk false >/dev/null 2>&1
    rm -f "$DATA_DIR/sd_uuid"
  fi

  if mnt_find "$STAGING_DIR"; then
    umount_one "$STAGING_DIR" "$_force"
  fi

  if mnt_find "$SD_BASE/$MOUNT_NAME"; then
    umount_one "$SD_BASE/$MOUNT_NAME" "$_force"
  fi

  if [ -n "$TARGET" ] && [ "$TARGET" != "$STAGING_DIR" ] && [ "$TARGET" != "$SD_BASE/$MOUNT_NAME" ]; then
    if mnt_find "$TARGET"; then
      umount_one "$TARGET" "$_force"
    fi
  fi

  if [ -f "$BINDS" ]; then
    for _m in $(sed '1!G;h;$!d' "$BINDS"); do
      umount_one "$_m" "$_force"
    done
    : > "$BINDS"
  fi

  rm -f "$DATA_DIR/mount_mode"
  sync
  clr_err
  say "[+] Unmounted"
  compute_status
  build_summary
  write_desc "$S_SUMMARY"
  return 0
}

# ------------------------------------------------------------------------------
# Folder mounts: folder A -> folder B (binds.conf)
# ------------------------------------------------------------------------------
BINDCONF=$DATA_DIR/binds.conf
VIEW_ROOTS="/storage/emulated/0 /mnt/user/0/emulated/0 /mnt/installer/0/emulated/0 /mnt/androidwritable/0/emulated/0 /mnt/pass_through/0/emulated/0 /mnt/runtime/default/emulated/0 /mnt/runtime/read/emulated/0 /mnt/runtime/write/emulated/0"
DST_DENY="/ /data /data/media /data/media/0 /data/adb /data/adb/modules /storage /system /vendor /product /system_ext /odm /proc /sys /dev /apex /mnt /sdcard"

init_bindconf() {
  [ -f "$BINDCONF" ] && return 0
  cat > "$BINDCONF" <<'EOT'
# Folder mounts. One per line:  id  source(A)  destination(B)  [options]
#   source      "@" or "@/sub/dir" = the mounted partition, or an absolute path
#   destination relative path = inside internal storage (/sdcard/<path>), or an absolute path
#   options     owner=none|auto|UID:GID   auto=0|1   pkg=name   stop=0|1   move=0|1
EOT
  chmod 0600 "$BINDCONF"
}

valid_id() { case "$1" in ""|*[!A-Za-z0-9_-]*) return 1 ;; esac; return 0; }
valid_pkg() {
  case "$1" in
    ""|.*|*.|*[!A-Za-z0-9_.]*|*..*) return 1 ;;
  esac
  case "$1" in
    *.*) return 0 ;;
  esac
  return 1
}
valid_path() {
  case "$1" in ""|*[!A-Za-z0-9_.@/+-]*|*..*|.|./*|*/./*|*/.|*//*) return 1 ;; esac
  case "$1" in @|@/*) return 0 ;; *@*) return 1 ;; esac
  return 0
}

entry_get() {
  [ -f "$BINDCONF" ] || return 1
  while read -r _a _b _c _d; do
    case "$_a" in ""|\#*) continue ;; esac
    if [ "$_a" = "$1" ]; then
      E_ID=$_a; E_SRC=$_b; E_DST=$_c; E_OPTS=$_d
      entry_parse
      return 0
    fi
  done < "$BINDCONF"
  return 1
}

entry_parse() {
  E_MODE=bind; E_OWNER=none; E_AUTO=1; E_UID=""; E_STOP=0; E_PKG_OPT=""; E_MOVE=0
  for _o in $E_OPTS; do
    case "$_o" in
      mode=*)  ;;
      owner=*) E_OWNER=${_o#owner=} ;;
      auto=*)  E_AUTO=${_o#auto=} ;;
      uid=*)   E_UID=${_o#uid=} ;;
      pkg=*)   E_PKG_OPT=${_o#pkg=} ;;
      stop=*)  E_STOP=${_o#stop=} ;;
      move=*)  E_MOVE=${_o#move=} ;;
    esac
  done
  case "$E_SRC" in
    @)   E_SRCP=$TARGET ;;
    @/*) E_SRCP=$TARGET${E_SRC#@} ;;
    *)   E_SRCP=$E_SRC ;;
  esac
  E_REL=""
  case "$E_DST" in
    /sdcard/*)             E_REL=${E_DST#/sdcard/} ;;
    /storage/emulated/0/*) E_REL=${E_DST#/storage/emulated/0/} ;;
    /data/media/0/*)       E_REL=${E_DST#/data/media/0/} ;;
    /*)                    E_REL="" ;;
    *)                     E_REL=$E_DST ;;
  esac
  E_PKG=""; E_KIND=""
  case "$E_REL" in
    Android/data/*|Android/obb/*)
      _p=${E_REL#Android/}
      E_KIND=${_p%%/*}
      _p=${_p#*/}
      E_PKG=${_p%%/*} ;;
  esac
  [ -n "$E_PKG_OPT" ] && E_PKG=$E_PKG_OPT
}

entry_dsts() {
  if [ -n "$E_REL" ]; then
    echo "$SD_BASE/$E_REL"
    for _b in $VIEW_ROOTS; do [ -d "$_b" ] && echo "$_b/$E_REL"; done
  else
    echo "$E_DST"
  fi
}

entry_statefile() { echo "$DATA_DIR/bind.$1"; }

entry_state() {
  _sf=$(entry_statefile "$1")
  [ -s "$_sf" ] || { echo unmounted; return; }
  read -r _k _v _rest < "$_sf"
  case "$_k" in
    M) if mnt_find "$_v"; then echo mounted; else echo unmounted; fi ;;
    *) echo unmounted ;;
  esac
}

pkg_uid() {
  for _pd in "/data/user/0/$1" "/data/data/$1"; do
    [ -d "$_pd" ] && { stat -c %u "$_pd" 2>/dev/null; return; }
  done
}

entry_apply_owner() {
  case "$E_OWNER" in
    none|"")
      chown 1023:1023 "$E_SRCP" 2>/dev/null
      chmod 2777 "$E_SRCP" 2>/dev/null
      chmod -R a+rwX "$E_SRCP" 2>/dev/null
      find "$E_SRCP" -xdev -type d -exec chmod 2777 {} + 2>/dev/null
      return 0 ;;
    auto)
      _u=$(pkg_uid "$E_PKG")
      if [ -z "$E_PKG" ] || [ -z "$_u" ]; then
        chown 1023:1023 "$E_SRCP" 2>/dev/null
        chmod 2777 "$E_SRCP" 2>/dev/null
        chmod -R a+rwX "$E_SRCP" 2>/dev/null
        find "$E_SRCP" -xdev -type d -exec chmod 2777 {} + 2>/dev/null
        return 0
      fi
      if [ "$E_KIND" = "obb" ]; then _g=1079; else _g=1078; fi
      _own="$_u:$_g" ;;
    *) _own=$E_OWNER ;;
  esac
  chown "$_own" "$E_SRCP" 2>/dev/null && chmod 2777 "$E_SRCP" 2>/dev/null \
    && say "[+] $E_ID: $E_SRCP is now owned by $_own (mode 2777)"
  chown -R "$_own" "$E_SRCP" 2>/dev/null
  chmod -R a+rwX "$E_SRCP" 2>/dev/null
  find "$E_SRCP" -xdev -type d -exec chmod 2777 {} + 2>/dev/null
  say "[+] $E_ID: contents of folder A are usable by $_own and Ubuntu"
}

move_tree() {
  ls -A "$1" 2>/dev/null | while IFS= read -r _n; do
    _f=$1/$_n; _t=$2/$_n
    if [ -d "$_f" ] && [ ! -L "$_f" ] && [ -d "$_t" ] && [ ! -L "$_t" ]; then
      move_tree "$_f" "$_t"
      rmdir "$_f" 2>/dev/null
    elif [ -e "$_t" ] || [ -L "$_t" ]; then
      if [ -f "$_f" ] && [ -f "$_t" ] && cmp -s "$_f" "$_t"; then
        rm -f "$_f" && echo moved >> "$_mc"
      else
        say "[~] $E_ID: '${_f#"$_mb"/}' exists in folder A with different content; left in folder B"
        echo skip >> "$_mc"
      fi
    else
      _me=$(mv "$_f" "$_t" 2>&1)
      if [ $? -eq 0 ]; then
        echo moved >> "$_mc"
        case "$E_OWNER" in none|"") chgrp -R 1023 "$_t" 2>/dev/null; chmod -R g+rwX "$_t" 2>/dev/null ;; esac
      else
        say "[!] $E_ID: could not move '${_f#"$_mb"/}': ${_me:-unknown error}"
        echo fail >> "$_mc"
      fi
    fi
  done
}

entry_move_in() {
  [ "$E_MOVE" = "1" ] && [ "$E_MODE" = "bind" ] || return 0
  _mb=$(entry_dsts | head -n 1)
  [ -d "$_mb" ] || return 0
  if mnt_find "$_mb"; then _log "$E_ID: move skipped, $_mb is already a mount point"; return 0; fi
  case "$E_SRCP/" in "$_mb"/*) say "[!] $E_ID: folder A is inside folder B; cannot move files"; return 11 ;; esac
  _mc=$DATA_DIR/.mvcount; : > "$_mc"
  move_tree "$_mb" "$E_SRCP"
  _mm=$(grep -c moved "$_mc" 2>/dev/null); _mf=$(grep -c fail "$_mc" 2>/dev/null)
  rm -f "$_mc"
  [ "${_mm:-0}" -gt 0 ] && say "[+] $E_ID: moved ${_mm} item(s) from $_mb to $E_SRCP"
  [ "${_mf:-0}" -gt 0 ] && return 3
  return 0
}

tree_own() {
  find "$1" -xdev ! -type l \( ! -uid "$2" -o ! -gid "$3" -o \( -type d ! -perm -2770 \) -o \( ! -type d ! -perm -0660 \) \) \
    -exec sh -c 'u=$1; g=$2; shift 2; chown "$u:$g" "$@" 2>/dev/null; chmod ug+rwX "$@" 2>/dev/null; for f; do [ -d "$f" ] && chmod g+s "$f" 2>/dev/null; done' sh "$2" "$3" {} + 2>/dev/null
  return 0
}

app_identity() {
  APP_UID=""; APP_GID=""
  [ -n "$E_KIND" ] && [ -n "$E_PKG" ] || return 1
  APP_UID=$(pkg_uid "$E_PKG")
  [ -n "$APP_UID" ] || return 1
  if [ "$E_KIND" = "obb" ]; then APP_GID=1079; else APP_GID=1078; fi
  return 0
}

entry_mount() {
  apply_sepolicy
  entry_get "$1" || { say "[!] no folder mount named '$1'"; return 1; }
  [ "$(entry_state "$1")" = "mounted" ] && { say "[=] $E_ID already mounted"; return 0; }

  case "$E_SRC" in
    @|@/*)
      if ! mounted_ours; then
        if [ "$2" = "auto" ]; then _log "$E_ID: skipped at boot, partition not mounted"; return 0; fi
        do_mount || { say "[!] $E_ID: cannot mount the partition first"; return 1; }
        [ "$(entry_state "$1")" = "mounted" ] && { say "[=] $E_ID already mounted"; return 0; }
      fi
      [ -d "$E_SRCP" ] || mkdir -p "$E_SRCP" 2>/dev/null ;;
  esac
  if [ ! -d "$E_SRCP" ]; then
    say "[!] $E_ID: source folder $E_SRCP does not exist"
    return 1
  fi
  if ! ce_ready; then say "[!] $E_ID: device not unlocked yet"; return 13; fi

  _dsts=$(entry_dsts)
  for _d in $_dsts; do
    for _x in $DST_DENY; do
      [ "$_d" = "$_x" ] && { say "[!] $E_ID: refusing destination $_d"; return 11; }
    done
    [ "$_d" = "$TARGET" ] && { say "[!] $E_ID: refusing destination $_d (partition mount point)"; return 11; }
    case "$_d/" in "$E_SRCP"/*) say "[!] $E_ID: destination is inside the source"; return 11 ;; esac
  done

  entry_sweep 1
  entry_move_in || return $?
  entry_apply_owner

  _sf=$(entry_statefile "$E_ID")
  : > "$_sf"
  _first=1
  for _d in $_dsts; do
    if mnt_find "$_d" && [ $_first -eq 0 ]; then _first=0; continue; fi
    _first=0
    mkdir -p "$_d" 2>/dev/null
    if _e=$(mount --bind "$E_SRCP" "$_d" 2>&1); then
      echo "M $_d" >> "$_sf"
      say "[+] $E_ID: $E_SRCP -> $_d"
    else
      say "[!] $E_ID: bind to $_d failed: $_e"
    fi
  done
  if [ ! -s "$_sf" ]; then rm -f "$_sf"; say "[!] $E_ID: nothing could be mounted"; return 3; fi
  [ "$E_STOP" = "1" ] && [ -n "$E_PKG" ] && am force-stop "$E_PKG" 2>/dev/null
  return 0
}

entry_sweep() {
  case "$E_SRC" in @|@/*) ;; *) return 0 ;; esac
  [ -n "$DEV_MM" ] || return 0
  for _sd in $(entry_dsts); do
    _sn=0
    while mnt_find "$_sd" && [ "$MI_MM" = "$DEV_MM" ] && [ "$_sn" -lt 8 ]; do
      if umount "$_sd" 2>/dev/null || { [ "$1" = "1" ] && umount -l "$_sd" 2>/dev/null; }; then
        _log "$E_ID: removed leftover mount at $_sd"
      else
        break
      fi
      _sn=$((_sn + 1))
    done
  done
  return 0
}

entry_umount() {
  entry_get "$1" || { say "[!] no folder mount named '$1'"; return 1; }
  _sf=$(entry_statefile "$1")
  [ -f "$_sf" ] || { entry_sweep "$2"; return 0; }
  _bad=0
  for _line in $(sed -e 's/ /|/g' "$_sf" | sed '1!G;h;$!d'); do
    _k=${_line%%|*}; _rest=${_line#*|}
    case "$_k" in
      M) umount_one "$_rest" "$2" || { _bad=1; say "[!] busy: $_rest"; } ;;
    esac
  done
  if [ $_bad -eq 0 ]; then
    entry_sweep "$2"
    rm -f "$_sf"
    say "[+] $1 unmounted"
    [ "$E_STOP" = "1" ] && [ -n "$E_PKG" ] && am force-stop "$E_PKG" 2>/dev/null
    return 0
  fi
  return 5
}

each_entry() {
  _ee_fn=$1; shift
  [ -f "$BINDCONF" ] || return 0
  _ee_ids=$(while read -r _a _rest; do case "$_a" in ""|\#*) ;; *) echo "$_a" ;; esac; done < "$BINDCONF")
  _ee_rc=0
  for _ee_i in $_ee_ids; do "$_ee_fn" "$_ee_i" "$@" || _ee_rc=$?; done
  return $_ee_rc
}

bind_mount_auto() {
  [ -f "$BINDCONF" ] || return 0
  for _i in $(while read -r _a _rest; do case "$_a" in ""|\#*) ;; *) echo "$_a" ;; esac; done < "$BINDCONF"); do
    entry_get "$_i" && [ "$E_AUTO" = "1" ] && entry_mount "$_i" auto
  done
  return 0
}

bind_umount_all() {
  [ -f "$BINDCONF" ] || return 0
  for _i in $(while read -r _a _rest; do case "$_a" in ""|\#*) ;; *) echo "$_a" ;; esac; done < "$BINDCONF"); do
    entry_umount "$_i" "$1" >/dev/null 2>&1
  done
  return 0
}

entries_count() {
  S_ENT_TOTAL=0; S_ENT_MOUNTED=0
  [ -f "$BINDCONF" ] || return 0
  while read -r _a _rest; do
    case "$_a" in ""|\#*) continue ;; esac
    S_ENT_TOTAL=$((S_ENT_TOTAL + 1))
    [ "$(entry_state "$_a")" = "mounted" ] && S_ENT_MOUNTED=$((S_ENT_MOUNTED + 1))
  done < "$BINDCONF"
}

bind_validate() {
  _vs=$1; _vd=$2; shift 2
  valid_path "$_vs" || { echo "bad source path"; return 2; }
  valid_path "$_vd" || { echo "bad destination path"; return 2; }
  for _x in $DST_DENY; do [ "$_vd" = "$_x" ] && { echo "refusing destination $_vd"; return 11; }; done
  for _o in "$@"; do
    case "$_o" in
      mode=bind|owner=none|owner=auto|auto=0|auto=1|stop=0|stop=1|move=0|move=1) ;;
      owner=[0-9]*:[0-9]*|uid=[0-9]*) case "${_o#*=}" in *[!0-9:]*) echo "bad option $_o"; return 2 ;; esac ;;
      pkg=*) valid_pkg "${_o#pkg=}" || { echo "bad package name '${_o#pkg=}'"; return 2; } ;;
      *) echo "bad option $_o"; return 2 ;;
    esac
  done
  return 0
}

bind_edit() {
  _be_id=$1; _be_s=$2; _be_d=$3; shift 3
  _be_new="$_be_id $_be_s $_be_d $*"
  entry_get "$_be_id" || { echo "no folder mount named '$_be_id'"; return 1; }
  _be_was=$(entry_state "$_be_id")
  _old_dsts=$(entry_dsts)
  entry_umount "$_be_id" 1 >/dev/null 2>&1
  for _od in $_old_dsts; do
    umount "$_od" 2>/dev/null || umount -l "$_od" 2>/dev/null
  done
  : > "$BINDCONF.tmp"
  set -f
  while IFS= read -r _l; do
    case "$_l" in ""|\#*) echo "$_l" >> "$BINDCONF.tmp"; continue ;; esac
    set -- $_l
    if [ "$1" = "$_be_id" ]; then echo "$_be_new" >> "$BINDCONF.tmp"; else echo "$_l" >> "$BINDCONF.tmp"; fi
  done < "$BINDCONF"
  set +f
  cat "$BINDCONF.tmp" > "$BINDCONF"; rm -f "$BINDCONF.tmp"
  echo "saved $_be_id"
  if [ "$_be_was" = "mounted" ]; then
    entry_mount "$_be_id" manual || { echo "saved, but remounting failed"; return 3; }
  fi
  return 0
}

entry_fixwrite() {
  entry_get "$1" || { echo "no folder mount named '$1'"; return 1; }
  [ -d "$E_SRCP" ] || { echo "source folder $E_SRCP does not exist"; return 1; }
  if app_identity; then
    chown "$APP_UID:$APP_GID" "$E_SRCP" 2>/dev/null; chmod 2770 "$E_SRCP" 2>/dev/null
    tree_own "$E_SRCP" "$APP_UID" "$APP_GID"
    say "[+] $E_ID: $E_SRCP is now owned by $APP_UID:$APP_GID ($E_PKG)"
    return 0
  fi
  find "$E_SRCP" -xdev ! -type l -exec chgrp 1023 {} + 2>&1 | tail -n 3
  find "$E_SRCP" -xdev ! -type l -exec chmod g+rwX {} + 2>&1 | tail -n 3
  find "$E_SRCP" -xdev -type d -exec chmod g+s {} + 2>&1 | tail -n 3
  say "[+] $E_ID: $E_SRCP is now group media_rw (1023), group-writable, setgid"
}

entry_test() {
  entry_get "$1" || { echo "status=off"; echo "msg=no such folder mount"; return 1; }
  if [ "$(entry_state "$E_ID")" != "mounted" ]; then echo "status=off"; echo "msg=Not mounted"; return 0; fi
  _dst=$(entry_dsts | head -n 1)
  _tn=.ud_rw_test_$$
  _st=ok; _msg="Read and write work (as root and as the Android media daemon)"
  _det=""
  _add() { _det="$_det
detail=$*"; }
  _add "folder A : $(ls -dnZ "$E_SRCP" 2>/dev/null || ls -dn "$E_SRCP" 2>/dev/null)"
  _add "folder B : $(ls -dnZ "$_dst" 2>/dev/null || ls -dn "$_dst" 2>/dev/null)"
  _lbl=$(ls -dZ "$_dst" 2>/dev/null)
  for _td in $(entry_dsts); do
    _tc=0
    while read -r _i1 _i2 _i3 _i4 _i5 _irest; do [ "$_i5" = "$_td" ] && _tc=$((_tc + 1)); done < /proc/self/mountinfo
    _add "mounts at $_td: $_tc"
    [ "$_tc" -gt 1 ] && [ "$_st" = ok ] && { _st=warn; _msg="Several mounts are stacked on folder B; unmount and mount again"; }
  done

  if mnt_find "$_dst"; then
    case ",$MI_OPTS," in *,ro,*) _st=fail; _msg="Mounted read-only"; _add "mount options: $MI_OPTS" ;; esac
  fi

  _rootok=0
  if [ "$_st" = ok ]; then
    if mkdir "$_dst/$_tn.d" 2>/dev/null && echo ok > "$_dst/$_tn" 2>/dev/null && [ "$(cat "$_dst/$_tn" 2>/dev/null)" = ok ]; then
      _rootok=1; _add "root       : create folder + file + read back: ok"
    else
      _st=fail; _msg="Even root cannot write here"
      _add "root       : write FAILED ($(df -k "$_dst" 2>/dev/null | tail -n 1))"
    fi
  fi

  _appdone=0
  if [ "$_rootok" = 1 ] && app_identity; then
    _appdone=1
    _muid=$(media_uid)
    rm -rf "$_dst/$_tn.d" "$_dst/$_tn" 2>/dev/null
    RA_GROUPS="1023,1078,1079,9997"
    _o=$(run_as "$_muid" 1023 "id; mkdir '$_dst/$_tn.d' && echo ok > '$_dst/$_tn' && [ \"\$(cat '$_dst/$_tn')\" = ok ]" 2>&1)
    _r=$?
    RA_GROUPS=""
    [ $_r -ne 99 ] && _add "ran as: $(echo "$_o" | tr '\n' ' ' | cut -c1-300)"
    if [ $_r -eq 99 ]; then
      _st=warn; _msg="Root works; cannot test media daemon groups"
    elif [ $_r -ne 0 ]; then
      _st=fail
      _msg="Permission problem: the Android media daemon cannot write in folder A"
      _add "as media daemon uid $_muid + groups 1023,1078,1079: create folder/file FAILED"
      _add "folder A top: $(ls -dn "$E_SRCP" 2>/dev/null)"
    else
      _add "media daemon (uid $_muid, groups 1023,1078,1079): ok"
    fi
    rm -rf "$_dst/$_tn.d" "$_dst/$_tn" 2>/dev/null
  fi

  if [ "$_rootok" = 1 ] && [ "$_appdone" = 0 ]; then
    _muid=$(pkg_uid com.google.android.providers.media.module); [ -z "$_muid" ] && _muid=$(pkg_uid com.android.providers.media.module); [ -z "$_muid" ] && _muid=10234
    rm -rf "$_dst/$_tn.d" "$_dst/$_tn" 2>/dev/null
    RA_GROUPS="1023,1078,1079,9997"
    run_as "$_muid" 1023 "mkdir '$_dst/$_tn.d' && echo ok > '$_dst/$_tn' && [ \"\$(cat '$_dst/$_tn')\" = ok ]" >/dev/null 2>&1
    _r=$?
    RA_GROUPS=""
    if [ $_r -eq 99 ]; then
      _st=warn; _msg="Root works; could not test as media daemon"
    elif [ $_r -ne 0 ]; then
      _st=fail
      _avc=$(logcat -d -b all -t 4000 2>/dev/null | grep -E "avc: +denied" | grep -E "media_rw_data_file|unlabeled" | tail -n 3)
      [ -z "$_avc" ] && _avc=$(dmesg 2>/dev/null | grep -E "avc: +denied" | grep -E "media_rw_data_file|unlabeled" | tail -n 3)
      if [ -n "$_avc" ]; then
        _msg="Blocked by SELinux: the media daemon is denied on this folder"
        _add "avc denials: $(echo "$_avc" | tr '\n' ' ')"
      else
        _msg="Blocked by file permissions: the media daemon cannot write in folder A"
      fi
      _add "as uid $_muid gid 1023: create folder/file FAILED"
    else
      _add "media daemon (uid $_muid, gid 1023): ok"
    fi
    rm -rf "$_dst/$_tn.d" "$_dst/$_tn" 2>/dev/null
  fi

  echo "status=$_st"
  echo "msg=$_msg"
  echo "$_det" | sed '/^$/d'
}

cmd_bind() {
  _sub=$1; [ $# -gt 0 ] && shift
  case "$_sub" in
    list)
      [ -f "$BINDCONF" ] || return 0
      while read -r _a _rest; do
        case "$_a" in ""|\#*) continue ;; esac
        entry_get "$_a" && echo "entry=$E_ID|$(entry_state "$E_ID")|$E_MODE|$E_AUTO|$E_SRC|$E_DST|$E_OWNER|$E_STOP|${E_PKG:-}|$E_MOVE"
      done < "$BINDCONF" ;;
    add)
      _id=$1; _s=$2; _dd=$3; [ $# -ge 3 ] && shift 3
      valid_id "$_id" || { echo "bad id (letters, digits, - and _ only)"; return 2; }
      bind_validate "$_s" "$_dd" "$@" || return $?
      init_bindconf
      entry_get "$_id" && { echo "'$_id' already exists (delete it first)"; return 2; }
      echo "$_id $_s $_dd $*" >> "$BINDCONF"
      echo "added $_id" ;;
    edit)
      _id=$1; _s=$2; _dd=$3; [ $# -ge 3 ] && shift 3
      valid_id "$_id" || { echo "bad id"; return 2; }
      bind_validate "$_s" "$_dd" "$@" || return $?
      lock || return 1
      bind_edit "$_id" "$_s" "$_dd" "$@"; _r=$?
      unlock; return $_r ;;
    test)
      valid_id "$1" || { echo "status=off"; echo "msg=bad id"; return 2; }
      entry_test "$1" ;;
    fixwrite)
      valid_id "$1" || { echo "bad id"; return 2; }
      lock || return 1
      entry_fixwrite "$1"; _r=$?
      unlock; return $_r ;;
    del)
      valid_id "$1" || { echo "bad id"; return 2; }
      lock || return 1
      entry_umount "$1" 0 || { unlock; echo "could not unmount $1; not deleted"; return 5; }
      grep -v "^$1[[:space:]]" "$BINDCONF" > "$BINDCONF.tmp" && cat "$BINDCONF.tmp" > "$BINDCONF"
      rm -f "$BINDCONF.tmp"; unlock
      echo "deleted $1" ;;
    mount)
      lock || return 1
      if [ "$1" = "all" ]; then each_entry entry_mount manual; else valid_id "$1" && entry_mount "$1" manual; fi
      _r=$?; unlock; return $_r ;;
    umount)
      _f=0; [ "$2" = "force" ] && _f=1
      lock || return 1
      if [ "$1" = "all" ]; then each_entry entry_umount "$_f"; else valid_id "$1" && entry_umount "$1" "$_f"; fi
      _r=$?; unlock; return $_r ;;
    packages)
      _filt=${1:-""}
      if [ -f "$MODDIR/listapps.dex" ]; then
        CLASSPATH="$MODDIR/listapps.dex" app_process /system/bin com.zen.mountdata.ListApps 2>/dev/null | { if [ -n "$_filt" ]; then grep -iF -- "$_filt"; else cat; fi; }
      else
        pm list packages -U 2>/dev/null | { if [ -n "$_filt" ]; then grep -iF -- "$_filt"; else cat; fi; } | while IFS= read -r _line; do
          case "$_line" in package:*) ;; *) continue ;; esac
          _pkg=${_line#package:}; _pkg=${_pkg%% *}
          _uid=""
          case "$_line" in *" uid:"*) _uid=${_line##* uid:}; _uid=${_uid%% *} ;; esac
          [ -n "$_uid" ] || _uid=$(pkg_uid "$_pkg")
          echo "pkg=$_pkg|name=$_pkg|uid=${_uid:-?}"
        done
      fi ;;
    *) echo "usage: bind list|add|edit|del|mount|umount|test|fixwrite|packages"; return 2 ;;
  esac
}

# ------------------------------------------------------------------------------
# Permission tools
# ------------------------------------------------------------------------------
media_uid() {
  _mu=$(pkg_uid com.google.android.providers.media.module)
  [ -z "$_mu" ] && _mu=$(pkg_uid com.android.providers.media.module)
  [ -z "$_mu" ] && _mu=10234
  echo "$_mu"
}

stop_scan() {
  _sp=$(cat "$DATA_DIR/.scan.pid" 2>/dev/null)
  [ -n "$_sp" ] && kill "$_sp" 2>/dev/null
  rm -f "$DATA_DIR/.scan.pid"
}

perm_scan() {
  _root=${1:-$TARGET}
  _cf=$DATA_DIR/.fixcount
  : > "$_cf"
  FIXCOUNT=$_cf $NICE_CMD find "$_root" -xdev -path "$TARGET/lost+found" -prune -o ! -type l \
    \( ! -gid 1023 -o \( -type d ! -perm -2777 \) -o \( ! -type d ! -perm -0666 \) \) \
    -exec sh -c 'chgrp 1023 "$@" 2>/dev/null; chmod a+rwX "$@" 2>/dev/null; for f; do [ -d "$f" ] && chmod 2777 "$f" 2>/dev/null; done; echo $# >> "$FIXCOUNT"' sh {} + 2>/dev/null &
  echo $! > "$DATA_DIR/.scan.pid"
  wait $!
  rm -f "$DATA_DIR/.scan.pid"
  PS_FIXED=0
  while read -r _n; do PS_FIXED=$((PS_FIXED + _n)); done < "$_cf"
  rm -f "$_cf"
}

autofix_on_mount() {
  [ "$AUTOFIX_PERMS" = "1" ] || return 0
  [ "$MOUNT_MODE" = "internal" ] || return 0
  mounted_ours || return 0
  say "[-] Auto-fix permissions: checking $TARGET (background)"
  (
    trap - EXIT
    if [ -n "$UD_BOOT" ]; then
      while :; do
        read -r _up _ < /proc/uptime; _up=${_up%.*}
        [ "${_up:-0}" -ge 120 ] && break
        sleep 5
      done
    fi
    mounted_ours || exit 0
    perm_scan "$TARGET"
    if [ "$PS_FIXED" -gt 0 ]; then
      echo "$(date '+%F %T') fixed $PS_FIXED entries" > "$DATA_DIR/autofix.last"
      _log "autofix: normalised $PS_FIXED entries"
      if [ -n "$(view_missing)" ]; then
        cmd_restart_media >/dev/null 2>&1
        sleep 3; wake_media
      fi
    else
      echo "$(date '+%F %T') nothing needed fixing" > "$DATA_DIR/autofix.last"
    fi
  ) >/dev/null 2>&1 </dev/null &
}

run_as() {
  if [ -n "$RA_GROUPS" ]; then
    if command -v setpriv >/dev/null 2>&1; then
      _ro=$(setpriv --reuid "$1" --regid "$2" --groups "$RA_GROUPS" id -G 2>/dev/null)
      if ra_has_groups "$_ro" "$RA_GROUPS"; then
        setpriv --reuid "$1" --regid "$2" --groups "$RA_GROUPS" sh -c "$3"; return $?
      fi
    fi
    _rs=""; for _g in $(echo "$RA_GROUPS" | tr ',' ' '); do _rs="$_rs -G $_g"; done
    # shellcheck disable=SC2086
    _ro=$(su -g "$2" $_rs "$1" -c 'id -G' 2>/dev/null)
    if ra_has_groups "$_ro" "$RA_GROUPS"; then
      # shellcheck disable=SC2086
      su -g "$2" $_rs "$1" -c "$3"; return $?
    fi
    return 99
  fi
  if command -v setpriv >/dev/null 2>&1; then
    setpriv --reuid "$1" --regid "$2" --clear-groups sh -c "$3"
  elif su "$1" -c true >/dev/null 2>&1; then
    su "$1" -c "$3"
  else
    return 99
  fi
}

ra_has_groups() {
  [ -n "$1" ] || return 1
  for _w in $(echo "$2" | tr ',' ' '); do
    case " $1 " in *" $_w "*) ;; *) return 1 ;; esac
  done
  return 0
}

view_missing() {
  [ "$MOUNT_MODE" = "internal" ] || return 0
  for _vr in /storage/emulated/0 /mnt/user/0/emulated/0; do
    [ -d "$_vr/Android" ] || continue
    ls -A "$TARGET" 2>/dev/null | head -n 300 | while IFS= read -r _vn; do
      [ -e "$_vr/$MOUNT_NAME/$_vn" ] || echo "$_vn"
    done
    return 0
  done
}

cmd_fixperms() {
  load_conf
  _lvl=${1:-rw}
  case "$_lvl" in read|rw) ;; *) echo "usage: fixperms read|rw [folder]"; return 2 ;; esac
  if ! mounted_ours; then
    echo "Mount the partition first."
    return 1
  fi
  FX_ROOT=$TARGET
  if [ -n "$2" ]; then
    valid_path "$2" || { echo "bad folder name"; return 2; }
    case "$2" in /*|@*) echo "give the folder relative to the partition root"; return 2 ;; esac
    FX_ROOT=$TARGET/$2
    [ -d "$FX_ROOT" ] || { echo "no such folder: $2"; return 1; }
  fi
  stop_scan
  say "[-] fixperms $_lvl on $FX_ROOT: group -> media_rw (1023); a+rwX; directories mode 2777"
  find "$FX_ROOT" -xdev ! -type l -exec chgrp 1023 {} + 2>/dev/null
  if [ "$_lvl" = "rw" ]; then
    find "$FX_ROOT" -xdev ! -type l -exec chmod a+rwX {} + 2>/dev/null
  else
    find "$FX_ROOT" -xdev ! -type l -exec chmod a+rX {} + 2>/dev/null
  fi
  find "$FX_ROOT" -xdev -type d -exec chmod 2777 {} + 2>/dev/null
  chown 1023:1023 "$TARGET" 2>/dev/null
  chmod 2777 "$TARGET" 2>/dev/null
  say "[+] Done. Android and Ubuntu can read/write."
}

cmd_access() {
  load_conf
  mounted_ours || { echo "Mount the partition first."; return 1; }
  echo "mode     : $MOUNT_MODE"
  echo "root dir : $(ls -ldnZ "$TARGET" 2>/dev/null || ls -ldn "$TARGET")"
  echo "-- top-level entries (mode uid gid name) --"
  ls -ln "$TARGET" 2>/dev/null | head -n 15
  echo "-- as the Android media daemon (uid 10234, gid 1023 media_rw) --"
  run_as 10234 1023 "ls '$TARGET' >/dev/null 2>&1 && echo 'list root : ok' || echo 'list root : DENIED'"
  _r=$?
  if [ $_r -eq 99 ]; then echo "(cannot switch uid here: no setpriv/su uid support)"; return 0; fi
  run_as 10234 1023 "touch '$TARGET/.ud_write_test' 2>/dev/null && { echo 'write root: ok'; rm -f '$TARGET/.ud_write_test'; } || echo 'write root: DENIED'"
  echo "-- what apps see ($SDPATH) --"
  echo "view     : $(android_view)"
}

cmd_layout() {
  load_conf
  echo "config  : DEV=$DEV_CFG PART_NAME=$PART_NAME MODE=$MOUNT_MODE"
  echo "layout  : ${LAYOUT:-n/a}"
  echo "device  : ${DEV_REAL:-none} $( [ -b "$DEV_REAL" ] && echo '(exists)' || echo '(missing)')"
}

cmd_fsck() {
  load_conf
  if dev_in_use; then
    echo "$DEV_REAL is mounted; unmount it first."
    return 5
  fi
  if ! command -v e2fsck >/dev/null 2>&1; then
    echo "e2fsck not found. Run it from Ubuntu: e2fsck -p -f $DEV_REAL"
    return 1
  fi
  say "[-] e2fsck -p -f $DEV_REAL"
  e2fsck -p -f "$DEV_REAL" 2>&1 | tail -n 20
  _r=$?
  clr_err
  return $_r
}

cmd_restart_media() {
  say "[-] Restarting MediaProvider"
  am force-stop com.google.android.providers.media.module 2>/dev/null
  am force-stop com.android.providers.media.module 2>/dev/null
  am force-stop com.android.providers.media 2>/dev/null
  say "[+] Done; reopen your file manager"
}

wake_media() {
  content query --uri content://media/external/file --projection _id >/dev/null 2>&1
}

ensure_android_view() {
  [ "$(android_view)" = "missing" ] || return 0
  say "[~] Storage does not show the mount to apps yet; restarting MediaProvider"
  cmd_restart_media >/dev/null 2>&1
  _i=0
  while [ $_i -lt 6 ]; do
    sleep 3
    wake_media
    if [ "$(android_view)" != "missing" ]; then
      say "[+] Apps can see the mount now"
      return 0
    fi
    _i=$((_i + 1))
  done
  say "[!] Still not visible to apps. Check mount.log."
  return 1
}

cmd_fixview() {
  load_conf
  mounted_ours || { echo "Mount the partition first."; return 1; }
  cmd_restart_media >/dev/null 2>&1
  sleep 3; wake_media
  say "[+] Apps can see the mount now"
  return 0
}

cmd_diag() {
  load_conf
  echo "== config =="
  echo "DEV=$DEV_CFG -> $DEV_REAL ($DEV_MM) PARTNAME=$DEV_PARTNAME"
  echo "MODE=$MOUNT_MODE MOUNT_NAME=$MOUNT_NAME SD_UUID=$SD_UUID"
  echo "TARGET=$TARGET SDPATH=$SDPATH AUTOMOUNT=$AUTOMOUNT"
  echo "== block =="; ls -l "$DEV_REAL" 2>&1
  echo "== superblock =="; echo "luks=$(rd 6 0) ext4magic=$(rd 2 540) f2fs=$(rd 4 256)"
  command -v blkid >/dev/null 2>&1 && blkid "$DEV_REAL" 2>&1
  echo "== android =="; echo "boot_completed=$(getprop sys.boot_completed) ce_available=$(getprop sys.user.0.ce_available) selinux=$(getenforce 2>/dev/null)"
  echo "== mounts =="; grep -E "$DEV_BASE|$STAGING_DIR|$MOUNT_NAME|media_rw|pass_through" /proc/self/mountinfo 2>/dev/null
  echo "== target =="; ls -ldZ "$TARGET" 2>&1
  echo "== log tail =="; tail -n 25 "$LOG" 2>/dev/null
}

cmd_set() {
  case "$1" in AUTOMOUNT|FIX_ROOT_PERMS|DISABLE_DATA_MOUNT|AUTOFIX_PERMS|MOUNT_MODE|MOUNT_NAME) ;; *) echo "unsupported key"; return 2 ;; esac
  case "$1" in
    MOUNT_MODE)
      case "$2" in sdcard|internal) ;; *) echo "value must be sdcard or internal"; return 2 ;; esac ;;
    MOUNT_NAME)
      case "$2" in ""|.|..|*/*|*" "*) echo "invalid mount folder name"; return 2 ;; esac ;;
    *)
      case "$2" in 0|1) ;; *) echo "value must be 0 or 1"; return 2 ;; esac ;;
  esac
  _was_mounted=0; mounted_ours && _was_mounted=1
  conf_put "$1" "$2"
  echo "$1=$2"
  if [ "$_was_mounted" = "1" ]; then
    case "$1" in
      MOUNT_MODE|MOUNT_NAME)
        say "[-] Mode or mount path changed; remounting..."
        do_umount 1
        load_conf
        do_mount ;;
    esac
  fi
  compute_status
  build_summary
  write_desc "$S_SUMMARY"
}

cmd_browse() {
  _bp=${1:-/}
  case "$_bp" in /*) ;; *) echo "err=path must be absolute"; return 2 ;; esac
  valid_path "$_bp" || { echo "err=invalid path"; return 2; }
  case "$_bp" in *@*) echo "err=invalid path"; return 2 ;; esac
  [ -d "$_bp" ] || { echo "err=not a folder"; return 1; }
  echo "cwd=$_bp"
  ls -1A "$_bp" 2>/dev/null | while IFS= read -r _e; do
    [ -d "$_bp/$_e" ] || continue
    echo "dir=$_e"
  done | head -n 500
  return 0
}

cmd_mkdir() {
  _mp=$1
  valid_path "$_mp" || { echo "invalid path"; return 2; }
  case "$_mp" in /*) ;; *) echo "path must be absolute"; return 2 ;; esac
  case "$_mp" in
    "$TARGET"/*|"$STAGING_DIR"/*) _own=1 ;;
    "$SD_BASE"/Android/*) _own=0 ;;
    "$SD_BASE"/*) _own=1 ;;
    *) echo "refusing: folders can only be created in the shared partition or internal storage"; return 11 ;;
  esac
  [ -d "$_mp" ] && { echo "exists"; return 0; }
  mkdir -p "$_mp" 2>/dev/null || { echo "could not create folder"; return 1; }
  if [ "$_own" = "1" ]; then chown 1023:1023 "$_mp" 2>/dev/null; chmod 2775 "$_mp" 2>/dev/null; fi
  echo "created"
}

cmd_log() {
  tail -n "${1:-60}" "$LOG" 2>/dev/null
}

cmd_log_export() {
  _ld=$SD_BASE/Download
  mkdir -p "$_ld" 2>/dev/null
  [ -d "$_ld" ] || { echo "cannot create $_ld"; return 1; }
  _lf=$_ld/mount_ubuntu_data_log_$(date '+%Y%m%d_%H%M%S').txt
  {
    echo "Mount Ubuntu Data $(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
    echo "exported: $(date '+%F %T')"
    echo "---- status ----"
    cmd_status
    echo "---- mount.log ----"
    cat "$LOG" 2>/dev/null
  } > "$_lf" 2>/dev/null || { echo "could not write $_lf"; return 1; }
  chown 1023:1023 "$_lf" 2>/dev/null
  chmod 0660 "$_lf" 2>/dev/null
  am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://${_lf}" >/dev/null 2>&1
  echo "Saved: /sdcard/Download/${_lf##*/}"
}

# ------------------------------------------------------------------------------
# Partition name (/dev/block/by-name/<name>)
# ------------------------------------------------------------------------------
pt_check() {
  if ! valid_partname "$1"; then
    echo "status=fail"; echo "msg=invalid name (letters, digits, . _ - only)"
    return 2
  fi
  use_partname "$1"
  preflight; _ptr=$?
  echo "device=$DEV_REAL"
  echo "partname=$DEV_PARTNAME"
  if [ $_ptr -eq 0 ]; then
    echo "status=ok"
    echo "msg=${PF_WARN:-found $DEV_REAL ($DEV_FS)}"
    return 0
  fi
  echo "status=fail"
  echo "msg=$PF_MSG"
  [ $_ptr -eq 10 ] && return 4
  return $_ptr
}

pt_apply() {
  _pa_new=$1; _pa_force=$2
  _pa_old=$PART_NAME; _pa_oldcfg=$DEV_CFG; _pa_oldreal=$DEV_REAL
  _pa_was=0; mounted_ours && _pa_was=1
  pt_check "$_pa_new"; _pa_rc=$?
  if [ $_pa_rc -ne 0 ]; then
    say "[!] partition not changed (still '$_pa_old')"
    return $_pa_rc
  fi
  if [ "$_pa_was" = 1 ] && [ "$DEV_REAL" = "$_pa_oldreal" ]; then
    conf_put PART_NAME "$_pa_new"; conf_put DEV auto
    say "[=] $_pa_new is already mounted from $DEV_REAL"
    return 0
  fi
  if [ "$_pa_was" = 1 ]; then
    say "[-] Unmounting the current partition first"
    do_umount "$_pa_force"; _pa_rc=$?
    if [ $_pa_rc -ne 0 ]; then
      say "[!] partition not changed (still '$_pa_old')"
      return $_pa_rc
    fi
  fi
  conf_put PART_NAME "$_pa_new"; conf_put DEV auto
  do_mount; _pa_rc=$?
  case $_pa_rc in
    0|13|14) return $_pa_rc ;;
  esac
  say "[!] mounting '$_pa_new' failed; going back to '$_pa_old'"
  conf_put PART_NAME "$_pa_old"; conf_put DEV "$_pa_oldcfg"
  [ "$_pa_was" = 1 ] && do_mount
  return $_pa_rc
}

cmd_partition() {
  _sub=$1; [ $# -gt 0 ] && shift
  case "$_sub" in
    get)
      echo "part_name=$PART_NAME"
      echo "device=$DEV_REAL" ;;
    test)
      pt_check "$1"; return $? ;;
    set)
      _pn=$1; _pf=0; [ "$2" = "force" ] && _pf=1
      if ! valid_partname "$_pn"; then
        echo "status=fail"; echo "msg=invalid name (letters, digits, . _ - only)"
        return 2
      fi
      lock || return 1
      pt_apply "$_pn" "$_pf"; _r=$?
      unlock; return $_r ;;
    *) echo "usage: partition get | test <name> | set <name> [force]"; return 2 ;;
  esac
}

cmd_format() {
  _fstype=$1
  case "$_fstype" in
    ext4|exfat) ;;
    *) echo "status=fail"; echo "msg=unsupported filesystem (use ext4 or exfat)"; return 2 ;;
  esac

  if [ ! -b "$DEV_REAL" ]; then
    echo "status=fail"; echo "msg=device $DEV_REAL not found"
    return 1
  fi

  for _pat in $PARTNAME_DENY; do
    # shellcheck disable=SC2254
    case "$DEV_PARTNAME" in
      $_pat) echo "status=fail"; echo "msg=refusing: $DEV_REAL is protected system partition '$DEV_PARTNAME'"; return 11 ;;
    esac
  done

  if mnt_find /data && [ -n "$DEV_MM" ] && [ "$MI_MM" = "$DEV_MM" ]; then
    echo "status=fail"; echo "msg=refusing: $DEV_REAL is Android system /data"; return 11
  fi

  say "[-] Formatting $DEV_REAL as $_fstype ..."
  _was_mounted=0
  mounted_ours && _was_mounted=1

  do_umount 1 >/dev/null 2>&1

  _rc=0
  if [ "$_fstype" = "ext4" ]; then
    if ! mke2fs -t ext4 -F -L "UBUNTU_DATA" "$DEV_REAL" >/dev/null 2>&1; then
      _rc=$?
    fi
  else
    if ! mkfs.exfat -L "UBUNTU_DATA" "$DEV_REAL" >/dev/null 2>&1; then
      _rc=$?
    fi
  fi

  if [ $_rc -ne 0 ]; then
    set_err "format as $_fstype failed (exit $_rc)"
    say "[!] Formatting $DEV_REAL as $_fstype failed"
    echo "status=fail"
    echo "msg=formatting failed (exit $_rc)"
    return $_rc
  fi

  say "[+] Successfully formatted $DEV_REAL as $_fstype"
  if [ "$_was_mounted" = "1" ]; then
    load_conf
    do_mount >/dev/null 2>&1
  fi

  echo "status=ok"
  echo "msg=Formatted $DEV_PARTNAME as $_fstype"
  return 0
}

# ------------------------------------------------------------------------------
# Boot + live description
# ------------------------------------------------------------------------------
cmd_boot_mount() {
  load_conf
  apply_sepolicy
  UD_BOOT=1; export UD_BOOT
  _log "=== boot-mount === DEV=$DEV_REAL MODE=$MOUNT_MODE boot_completed=$(getprop sys.boot_completed)"
  _i=0
  while ! ce_ready; do
    _i=$((_i + 1))
    [ $_i -gt 900 ] && { _log "gave up waiting for unlock"; return 13; }
    sleep 2
  done
  sleep 3
  lock || return 1
  if [ "$DISABLE_DATA_MOUNT" = "1" ]; then
    _log "DISABLE_DATA_MOUNT=1; partition not mounted at boot"
    bind_mount_auto
    _r=0
  elif [ "$AUTOMOUNT" = "1" ]; then
    do_mount
    _r=$?
  else
    _log "AUTOMOUNT=0; partition not mounted at boot"
    bind_mount_auto
    _r=0
  fi
  unlock
  return $_r
}

write_desc() {
  _prop=$MODDIR/module.prop
  [ -f "$_prop" ] || return 1
  _cur=$(grep '^description=' "$_prop" 2>/dev/null)
  [ "$_cur" = "description=$1" ] && return 0
  _t=$DATA_DIR/.prop.$$
  grep -v '^description=' "$_prop" > "$_t" && echo "description=$1" >> "$_t" && cat "$_t" > "$_prop"
  rm -f "$_t"
}

cmd_daemon() {
  if [ -f "$PIDFILE" ]; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$_p" ] && [ "$_p" != "$$" ] && kill -0 "$_p" 2>/dev/null; then
      kill -9 "$_p" 2>/dev/null
      sleep 1
    fi
  fi
  echo $$ > "$PIDFILE"
  trap 'rm -f "$PIDFILE"; exit 0' TERM INT
  while :; do
    if [ -e "$MODDIR/disable" ] || [ -e "$MODDIR/remove" ]; then
      break
    fi
    load_conf
    compute_status
    build_summary
    write_desc "$S_SUMMARY"
    trim_log
    sleep 20
  done
  rm -f "$PIDFILE"
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------
main() {
  case "$1" in ""|init-config|layout|-h|--help) ;; *) ensure_init_ns "$@" ;; esac
  cmd=$1
  [ $# -gt 0 ] && shift
  case "$cmd" in
    init-config) cmd_init_config ;;
  esac
  [ -f "$CONF" ] || cmd_init_config
  init_bindconf
  load_conf

  case "$cmd" in
    status)        cmd_status ;;
    info)          cmd_info ;;
    mount)         lock || exit 1; do_mount; r=$?; unlock; exit $r ;;
    umount|unmount)
      f=0; [ "$1" = "force" ] && f=1
      lock || exit 1; do_umount "$f"; r=$?; unlock; exit $r ;;
    toggle)
      lock || exit 1
      if mounted_ours; then do_umount 0; else do_mount; fi
      r=$?; unlock; exit $r ;;
    bind)          cmd_bind "$@"; exit $? ;;
    set)           cmd_set "$1" "$2" ;;
    partition)     cmd_partition "$@"; exit $? ;;
    format)        lock || exit 1; cmd_format "$@"; r=$?; unlock; exit $r ;;
    browse)        cmd_browse "$1"; exit $? ;;
    mkdir)         cmd_mkdir "$1"; exit $? ;;
    fixperms)      cmd_fixperms "$1" "$2"; exit $? ;;
    access)        cmd_access ;;
    layout)        cmd_layout ;;
    fsck)          cmd_fsck ;;
    restart-media) cmd_restart_media ;;
    fixview)       cmd_fixview; exit $? ;;
    diag)          cmd_diag ;;
    log)           cmd_log "$1" ;;
    log-export)    cmd_log_export; exit $? ;;
    boot-mount)    cmd_boot_mount ;;
    daemon)        cmd_daemon ;;
    init-config)   : ;;
    packages)      cmd_bind packages "$@"; exit $? ;;
    *)
      sed -n '2,/^# =====/p' "$0" | sed 's/^# \{0,1\}//'
      exit 2 ;;
  esac
}

[ -n "$UD_LIB" ] || main "$@"
