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
#   set KEY 0|1       change AUTOMOUNT / FIX_ROOT_PERMS / DISABLE_DATA_MOUNT in config.sh
#   partition get|test <name>|set <name> [force]
#                     partition = /dev/block/by-name/<name> (default "data"); test checks it exists
#                     and is ext4; set tests, saves, unmounts the old one and mounts the new one
#   browse <dir>      list sub-folders of an absolute path (WebUI folder picker)
#   mkdir <dir>       create a folder inside the partition or internal storage (folder picker)
#   bind list|add|del|mount|umount|vfs-check|vfs-test   folder A -> folder B mounts (binds.conf)
#   packages [filter] list installed apps (pkg= uid=) for the VFS picker
#   layout            show which block device the partition name resolves to
#   access            test what the Android media daemon (gid media_rw) can read/write
#   fixperms read|rw  group -> media_rw (1023) + g+rX (read) or g+rwX (rw), recursive, symlink-safe
#   fsck              e2fsck -p on the (unmounted) partition
#   restart-media     force-stop MediaProvider so /sdcard re-reads the mount
#   fixview           restart MediaProvider and wait until apps can see the mount in /sdcard
#   diag              diagnostics dump
#   log [N]           last N log lines (default 60)
#   boot-mount        used by service.sh (waits for first unlock, then mounts)
#   daemon            keeps the module.prop description up to date
#   init-config       create config.sh if missing
#
# Exit codes: 0 ok, 1 generic, 2 bad args, 3 mount failed, 4 device absent,
#             5 busy, 11 refused (safety), 12 encrypted / not ext4, 13 not unlocked,
#             14 partition mount disabled (DISABLE_DATA_MOUNT=1)
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

mkdir -p "$DATA_DIR" 2>/dev/null
chmod 0700 "$DATA_DIR" 2>/dev/null

# ------------------------------------------------------------------------------
# Mount namespace: mounts made from a manager app / WebUI / "su" can end up in a private
# namespace that only root file managers share. Android apps (MediaProvider) never see
# those. So every command re-runs itself inside init's (pid 1) namespace.
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
    _log "WARNING: running in a private mount namespace and no nsenter found; Android apps may not see the mount"
    return 0
  fi
  # shellcheck disable=SC2086
  if ! $NSE -t 1 -m -- true >/dev/null 2>&1; then
    _log "WARNING: nsenter into init's mount namespace failed; continuing in the current namespace"
    return 0
  fi
  _log "re-running '$*' inside init's mount namespace"
  UD_NS=1; export UD_NS
  # shellcheck disable=SC2086
  exec $NSE -t 1 -m -- sh "$MODDIR/ubuntu-data.sh" "$@"
}

# ------------------------------------------------------------------------------
# Config
# ------------------------------------------------------------------------------
# DEV=auto: /dev/block/by-name/<PART_NAME> (default name: "data")
valid_partname() {
  case "$1" in
    ""|.|..|-*|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  [ "${#1}" -le 36 ]
}

# Needs DEV_CFG (auto or an explicit /dev path) and PART_NAME. Sets DEV DEV_REAL DEV_BASE DEV_MM DEV_PARTNAME LAYOUT.
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

use_partname() { # <name>: resolve another partition name without touching config.sh
  PART_NAME=$1
  DEV_CFG=auto
  resolve_dev
}

load_conf() {
  DEV=auto
  PART_NAME=data
  MOUNT_NAME=ubuntu
  AUTOMOUNT=0
  FIX_ROOT_PERMS=1
  DISABLE_DATA_MOUNT=0
  EXTRA_BINDS=""
  PUBLISH_TOOLS=1
  PARTNAME_DENY="userdata metadata persist* cache misc frp keystore devinfo oplusreserve* oem* modem* super boot* init_boot* vendor_boot* dtbo* vbmeta* recovery*"
  # shellcheck disable=SC1090
  [ -f "$CONF" ] && . "$CONF"

  case "$MOUNT_NAME" in
    ""|.|..|*/*|*" "*) MOUNT_NAME=ubuntu ;;
  esac
  valid_partname "$PART_NAME" || PART_NAME=data
  [ -n "$DEV" ] || DEV=auto
  [ "$DISABLE_DATA_MOUNT" = "1" ] || DISABLE_DATA_MOUNT=0
  TARGET=$SD_BASE/$MOUNT_NAME
  SDPATH=/sdcard/$MOUNT_NAME

  DEV_CFG=$DEV
  resolve_dev
  # log only when something changed (status/daemon call this every few seconds)
  _lc="DEV_CFG=$DEV_CFG DEV_REAL=$DEV_REAL PARTNAME=$DEV_PARTNAME layout=$LAYOUT"
  if [ "$_lc" != "$(cat "$DATA_DIR/.lastconf" 2>/dev/null)" ]; then
    _log "load_conf: $_lc"
    echo "$_lc" > "$DATA_DIR/.lastconf" 2>/dev/null
  fi
}

conf_put() { # <KEY> <VALUE>: set one key in config.sh
  cmd_init_config
  grep -v "^$1=" "$CONF" > "$CONF.tmp" 2>/dev/null
  echo "$1=$2" >> "$CONF.tmp"
  cat "$CONF.tmp" > "$CONF"
  rm -f "$CONF.tmp"
}

cmd_init_config() {
  if [ -f "$CONF" ]; then
    # upgrade from <= v2.6 (userdata + offset): add the partition name key
    grep -q '^PART_NAME=' "$CONF" 2>/dev/null || printf '\nPART_NAME=data\n' >> "$CONF"
    return 0
  fi
  cat > "$CONF" <<'EOF'
# Mount Ubuntu Data - configuration (sourced as shell). Author: zen
# Block device of the shared ext4 partition. "auto" = /dev/block/by-name/<PART_NAME>.
# Or set it explicitly, e.g.  DEV=/dev/block/sda18
DEV=auto
# Partition name under /dev/block/by-name/ (changeable in the WebUI)
PART_NAME=data
# Folder name in Android internal storage: /sdcard/<MOUNT_NAME>
MOUNT_NAME=ubuntu
# 1 = mount automatically after boot (once the user has unlocked the device). Default 0 = off.
AUTOMOUNT=0
# 1 = chown the partition root to media_rw (1023) with setgid so Android apps can write
FIX_ROOT_PERMS=1
# 1 = never mount the shared partition (default 0 = mount it). ONLY for dual boot Android + Linux,
# where the additional sdaX partition is mounted in both systems. Do not use it without dual boot.
DISABLE_DATA_MOUNT=0
# Extra bind mounts made after the main mount, space separated "source:destination".
# "@" means the mounted partition. Use this to expose it as /data inside an Ubuntu
# chroot/container rootfs that lives on Android, e.g.
#   EXTRA_BINDS="@:/data/ubuntu/data"
EXTRA_BINDS=""
# 1 = copy ubuntu/setup-sharing.sh onto the partition (/.ubuntu-data-tools/) so Ubuntu can run it
PUBLISH_TOOLS=1
EOF
  chmod 0600 "$CONF"
}

# ------------------------------------------------------------------------------
# Logging / errors / locking
# ------------------------------------------------------------------------------
_log() {
  echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null
}
say() {
  echo "$*"
  _log "$*"
}
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
    # a lock directory that never got a pid file (holder died in between) is stale after a few seconds
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
# mnt_find <mountpoint>: sets MI_MM / MI_FS / MI_OPTS for the top-most mount there.
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

# true when any mount in this namespace uses the block device
dev_in_use() {
  [ -n "$DEV_MM" ] || return 1
  while read -r _id _par _mm _rest; do
    [ "$_mm" = "$DEV_MM" ] && return 0
  done < /proc/self/mountinfo
  return 1
}

mounted_ours() {
  mnt_find "$TARGET" && [ -n "$DEV_MM" ] && [ "$MI_MM" = "$DEV_MM" ]
}

ce_ready() {
  [ "$(getprop sys.boot_completed)" = "1" ] || return 1
  [ "$(getprop sys.user.0.ce_available)" = "true" ] && [ -d "$SD_BASE" ] && return 0
  [ -d "$SD_BASE/Android" ]
}

# ------------------------------------------------------------------------------
# Raw superblock probing (needs only dd + od, no blkid/tune2fs)
# ------------------------------------------------------------------------------
rd() { # <bs> <skip> -> hex bytes separated by single spaces
  dd if="$DEV_REAL" bs="$1" skip="$2" count=1 2>/dev/null | od -An -v -tx1 | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'
}

# Sets PF_MSG; returns 0 ok, 10 absent, 11 refused, 12 encrypted/not-ext4
preflight() {
  PF_MSG=""
  PF_WARN=""
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
  _log "preflight: DEV=$DEV_REAL ext4magic=$_ext4magic f2fs=$(rd 4 256)"
  if [ "$_ext4magic" != "53 ef" ]; then
    if [ "$(rd 4 256)" = "10 20 f5 f2" ]; then
      PF_MSG="$DEV is f2fs, not ext4 (format it: mkfs.ext4 $DEV)"
    else
      PF_MSG="$DEV has no ext4 filesystem (unformatted or another type); magic=$_ext4magic"
    fi
    return 12
  fi

  # ext4 INCOMPAT_ENCRYPT (0x10000) is only a capability flag, but warn about it.
  set -- $(rd 4 280)
  if [ -n "$3" ] && [ $(( 0x$3 & 1 )) -ne 0 ]; then
    PF_WARN="ext4 'encrypt' feature flag is set; any fscrypt-protected folders will look scrambled without their key"
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

# Is the mount visible through Android's own storage view (FUSE)? ok|missing|n/a
android_view() {
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

  if mnt_find "$TARGET"; then
    if [ -n "$DEV_MM" ] && [ "$MI_MM" = "$DEV_MM" ]; then
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
    else
      S_STATE=conflict
      S_ERR="something else ($MI_FS) is already mounted on $TARGET"
    fi
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
      S_SUMMARY="🟢 Mounted · $_dn ${S_FS:-ext4} ${S_RW} → $SDPATH · $(fmt_kb "$S_USED") of $(fmt_kb "$S_SIZE") used (${S_PCT}%)"
      [ "$S_SEL" = "plain" ] && S_SUMMARY="$S_SUMMARY · ⚠ no SELinux label"
      [ "$S_BINDS" -gt 0 ] && S_SUMMARY="$S_SUMMARY · $S_BINDS bind mount(s)"
      [ "$S_VIEW" = "missing" ] && S_SUMMARY="$S_SUMMARY · ⚠ not yet visible in $SDPATH"
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
  echo "last_error=$S_ERR"
  if vfs_ready_cached; then echo "vfs_available=1"; else echo "vfs_available=0"; fi
  echo "summary=$S_SUMMARY"
}

cmd_info() {
  compute_status
  build_summary
  echo "$S_SUMMARY"
  echo "device      : $DEV_REAL (${DEV_PARTNAME:-no partname})"
  echo "mountpoint  : $TARGET  (Android: $SDPATH)"
  echo "automount   : $AUTOMOUNT"
  echo "mount off   : $DISABLE_DATA_MOUNT (1 = partition mount disabled)"
  echo "android view: $S_VIEW"
  [ -n "$S_ERR" ] && echo "last error  : $S_ERR"
  return 0
}

# ------------------------------------------------------------------------------
# Mount
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

# Mirror the mount into the lower-filesystem views that Android keeps around, in case
# the mount did not propagate into them. Plain bind mounts only.
mount_runtime_views() {
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

do_mount() {
  load_conf
  if mounted_ours; then
    say "[=] Already mounted at $TARGET"
    return 0
  fi
  if [ "$DISABLE_DATA_MOUNT" = "1" ]; then
    say "[=] Partition mount is disabled (DISABLE_DATA_MOUNT=1, dual-boot option). Switch it off in the WebUI to mount."
    return 14
  fi
  if mnt_find "$TARGET"; then
    set_err "something else ($MI_FS) is already mounted on $TARGET"
    say "[!] something else ($MI_FS) is already mounted on $TARGET"
    return 11
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

  mkdir -p "$TARGET" 2>/dev/null
  if [ ! -d "$TARGET" ]; then
    set_err "cannot create $TARGET"
    say "[!] cannot create $TARGET"
    return 3
  fi

  say "[-] Mounting $DEV_REAL on $TARGET ..."
  _ok=0
  _err=""
  _lbl=u:object_r:media_rw_data_file:s0
  _mode=""
  for _try in ctx fsctx plain; do
    case "$_try" in
      ctx)   _opts="rw,noatime,nosuid,nodev,context=$_lbl" ;;
      fsctx) _opts="rw,noatime,nosuid,nodev,fscontext=$_lbl,defcontext=$_lbl" ;;
      plain) _opts="rw,noatime,nosuid,nodev" ;;
    esac
    if _err=$(mount -t ext4 -o "$_opts" "$DEV_REAL" "$TARGET" 2>&1); then
      _ok=1; _mode=$_try
      say "[+] mounted ($_opts)"
      break
    fi
    _log "mount failed with '$_opts': $_err"
  done
  if [ $_ok -eq 1 ]; then
    echo "$_mode" > "$DATA_DIR/mount_mode"
    [ "$_mode" = "plain" ] && say "[~] Mounted WITHOUT an SELinux label: Android apps may be denied access. Run 'diag' and check sepolicy.rule loaded (reboot after install)."
  fi
  if [ $_ok -ne 1 ]; then
    set_err "mount failed: $_err (if the filesystem is dirty run: ubuntu-data.sh fsck)"
    say "[!] Mount failed: $_err"
    _log "dmesg avc: $(dmesg 2>/dev/null | grep -i 'avc.*sda18\|avc.*ubuntu\|denied.*ubuntu' | tail -5)"
    return 3
  fi

  if [ "$FIX_ROOT_PERMS" = "1" ]; then
    chown 1023:1023 "$TARGET" 2>/dev/null
    chmod 2775 "$TARGET" 2>/dev/null
    if [ ! -f "$TARGET/.android_perms_initialized" ]; then
      say "[-] Initializing Android media_rw permissions on $TARGET (background)..."
      (
        find "$TARGET" -xdev ! -type l -exec chgrp 1023 {} + 2>/dev/null || true
        find "$TARGET" -xdev ! -type l -exec chmod g+rwX {} + 2>/dev/null || true
        find "$TARGET" -xdev -type d -exec chmod 2775 {} + 2>/dev/null || true
        touch "$TARGET/.android_perms_initialized" 2>/dev/null || true
        _log "[+] Android media_rw permissions initialized."
      ) >/dev/null 2>&1 </dev/null &
    fi
  fi

  publish_tools
  : > "$BINDS"
  mount_runtime_views
  mount_extra_binds
  clr_err
  say "[+] SUCCESS: $DEV_REAL mounted at $TARGET (Android: $SDPATH)"
  bind_mount_auto
  ensure_android_view
  return 0
}

# ------------------------------------------------------------------------------
# Umount
# ------------------------------------------------------------------------------
umount_one() { # <path> <force> ; returns 0 if gone, 1 if still mounted
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
  bind_umount_all "$_force"
  if ! mnt_find "$TARGET"; then
    say "[=] Nothing mounted at $TARGET"
    : > "$BINDS" 2>/dev/null
    return 0
  fi
  if [ -n "$DEV_MM" ] && [ "$MI_MM" != "$DEV_MM" ]; then
    say "[!] $TARGET is not mounted from $DEV_REAL; leaving it alone"
    return 11
  fi

  sync
  _bad=0
  if [ -f "$BINDS" ]; then
    for _m in $(sed '1!G;h;$!d' "$BINDS"); do
      umount_one "$_m" "$_force" || { _bad=1; say "[!] busy: $_m"; }
    done
  fi
  if [ $_bad -eq 0 ] && umount_one "$TARGET" "$_force"; then
    : > "$BINDS"
    rm -f "$DATA_DIR/mount_mode"
    sync
    clr_err
    say "[+] Unmounted $TARGET"
    return 0
  fi
  say "[!] Unmount failed: still in use (Ubuntu running or a file manager open?). Stop it, or use: umount force"
  return 5
}

# ------------------------------------------------------------------------------
# Folder mounts: folder A (on the partition or anywhere) -> folder B (anywhere)
#   binds.conf line:  <id> <source A> <destination B> [mode=bind|vfs] [owner=none|auto|UID:GID]
#                     [auto=0|1] [pkg=name] [uid=N] [stop=0|1]
#   source: "@" / "@/sub" = the mounted partition, or an absolute path
#   destination: relative = inside internal storage (/sdcard/<dst>), or absolute "anywhere"
#   mode=bind : real bind mount, visible to every app
#   mode=vfs  : Hybrid Mount VFS redirect for one app uid only (no mount entry). pkg= is required.
#               Old mode=auto is read as vfs when pkg= or uid= is set, otherwise as bind.
# ------------------------------------------------------------------------------
BINDCONF=$DATA_DIR/binds.conf
HM=/data/adb/modules/hybrid_mount/hybrid-mount
VIEW_ROOTS="/mnt/androidwritable/0/emulated/0 /mnt/pass_through/0/emulated/0 /mnt/runtime/default/emulated/0 /mnt/runtime/read/emulated/0 /mnt/runtime/write/emulated/0"
DST_DENY="/ /data /data/media /data/media/0 /data/adb /data/adb/modules /storage /system /vendor /product /system_ext /odm /proc /sys /dev /apex /mnt /sdcard"

init_bindconf() {
  [ -f "$BINDCONF" ] && return 0
  cat > "$BINDCONF" <<'EOT'
# Folder mounts. One per line:  id  source(A)  destination(B)  [options]
#   source      "@" or "@/sub/dir" = the mounted partition, or an absolute path
#   destination relative path = inside internal storage (/sdcard/<path>), or an absolute path
#   options     mode=bind|vfs   owner=none|auto|UID:GID   auto=0|1   pkg=name   stop=0|1
#   mode=vfs redirects folder B to folder A for that one app (Hybrid Mount). Example:
#   game1  @/games/mygame  Android/data/com.example.game/files  mode=vfs pkg=com.example.game stop=1
# Bind mount example (every app sees it):
#   game1  @/games/mygame  Android/data/com.example.game/files  owner=auto stop=1
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

# entry_get <id> -> E_ID E_SRC E_DST E_OPTS (+ parsed E_MODE E_OWNER E_AUTO E_UID E_STOP, E_REL, E_PKG)
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
  E_MODE=bind; E_OWNER=none; E_AUTO=1; E_UID=""; E_STOP=0; E_PKG_OPT=""
  for _o in $E_OPTS; do
    case "$_o" in
      mode=*)  E_MODE=${_o#mode=} ;;
      owner=*) E_OWNER=${_o#owner=} ;;
      auto=*)  E_AUTO=${_o#auto=} ;;
      uid=*)   E_UID=${_o#uid=} ;;
      pkg=*)   E_PKG_OPT=${_o#pkg=} ;;
      stop=*)  E_STOP=${_o#stop=} ;;
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
  # mode=auto used to mean "VFS if present, else a global bind". That hid which
  # apps could see the folder. Keep old lines working: vfs only when an app was named.
  if [ "$E_MODE" = "auto" ]; then
    if [ -n "$E_PKG_OPT" ] || [ -n "$E_UID" ]; then E_MODE=vfs; else E_MODE=bind; fi
  fi
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
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

entry_state() { # <id> -> mounted|unmounted
  _sf=$(entry_statefile "$1")
  [ -s "$_sf" ] || { echo unmounted; return; }
  read -r _k _v _rest < "$_sf"
  case "$_k" in
    M) if mnt_find "$_v"; then echo mounted; else echo unmounted; fi ;;
    V) # VFS rules are runtime-only: a state file from an earlier boot is stale
       if [ "$(cat "$_sf.boot" 2>/dev/null)" = "$(boot_id)" ]; then echo mounted; else echo unmounted; fi ;;
    *) echo unmounted ;;
  esac
}

pkg_uid() { # <pkg> -> uid or empty
  for _pd in "/data/user/0/$1" "/data/data/$1"; do
    [ -d "$_pd" ] && { stat -c %u "$_pd" 2>/dev/null; return; }
  done
}

entry_apply_owner() {
  case "$E_OWNER" in
    none|"") return 0 ;;
    auto)
      _u=$(pkg_uid "$E_PKG")
      if [ -z "$E_PKG" ] || [ -z "$_u" ]; then
        say "[~] $E_ID: owner=auto needs a destination under Android/data|obb/<package> of an installed app; skipped"
        return 0
      fi
      if [ "$E_KIND" = "obb" ]; then _g=1079; else _g=1078; fi
      _own="$_u:$_g" ;;
    *) _own=$E_OWNER ;;
  esac
  chown "$_own" "$E_SRCP" 2>/dev/null && chmod 2770 "$E_SRCP" 2>/dev/null \
    && say "[+] $E_ID: $E_SRCP is now owned by $_own (mode 2770)"
}

entry_mount() { # <id> <ctx: manual|auto>
  entry_get "$1" || { say "[!] no folder mount named '$1'"; return 1; }
  [ "$(entry_state "$1")" = "mounted" ] && { say "[=] $E_ID already mounted"; return 0; }

  case "$E_MODE" in bind|vfs) ;; *) say "[!] $E_ID: bad mode '$E_MODE'"; return 1 ;; esac

  case "$E_SRC" in
    @|@/*)
      if ! mounted_ours; then
        if [ "$2" = "auto" ]; then _log "$E_ID: skipped at boot, partition not mounted"; return 0; fi
        do_mount || { say "[!] $E_ID: cannot mount the partition first"; return 1; }
        # do_mount mounts auto entries itself; don't bind this one a second time
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
    [ "$_d" = "$TARGET" ] && { say "[!] $E_ID: refusing destination $_d (the partition's own mount point)"; return 11; }
    case "$_d/" in "$E_SRCP"/*) say "[!] $E_ID: destination is inside the source"; return 11 ;; esac
  done

  entry_apply_owner

  _sf=$(entry_statefile "$E_ID")
  : > "$_sf"
  _done=0
  _m=$E_MODE
  if [ "$_m" = "vfs" ] || [ "$_m" = "auto" ]; then
    if entry_vfs_add; then _done=1; elif [ "$_m" = "vfs" ]; then
      say "[!] $E_ID: VFS backend failed (mode=vfs does not fall back to a real mount)"
      rm -f "$_sf"; return 3
    else
      say "[~] $E_ID: VFS unavailable, using bind mount"
    fi
  fi
  if [ $_done -eq 0 ]; then
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
  fi
  [ "$E_STOP" = "1" ] && [ -n "$E_PKG" ] && am force-stop "$E_PKG" 2>/dev/null
  return 0
}

# Hybrid Mount VFS: redirect the path an app opens onto folder A, for that app's uid only.
# `hybrid-mount vfs rule add <virtual> <real> --uid UID`. UID 0 means every process, so it is refused.
# Rules are runtime-only; boot-mount reapplies them. doctor may exit 0 when the provider is down,
# so availability is checked via "responds": true in `vfs doctor --json`.
vfs_ready_cached() { # status is polled every few seconds; do not run doctor each time
  [ -x "$HM" ] || return 1
  _vc=$DATA_DIR/.vfs_cache
  _vn=$(date +%s); _vt=$(stat -c %Y "$_vc" 2>/dev/null || echo 0)
  if [ -s "$_vc" ] && [ $((_vn - _vt)) -lt 30 ]; then
    [ "$(cat "$_vc")" = "1" ]
    return
  fi
  if vfs_ready; then echo 1 > "$_vc"; return 0; fi
  echo 0 > "$_vc"
  return 1
}

vfs_ready() {
  VFS_MSG=""
  [ -x "$HM" ] || { VFS_MSG="Hybrid Mount is not installed"; return 1; }
  _vr=$("$HM" vfs doctor --json 2>/dev/null)
  if [ -n "$_vr" ] && echo "$_vr" | grep -q '"responds"'; then
    if echo "$_vr" | grep -Eq '"responds"[[:space:]]*:[[:space:]]*true'; then
      VFS_MSG="Hybrid Mount VFS provider is responding"
      return 0
    fi
    VFS_MSG="Hybrid Mount VFS provider is not responding"
    return 1
  fi
  _vr=$("$HM" vfs doctor 2>&1)
  if [ $? -ne 0 ]; then
    VFS_MSG=${_vr:-"vfs doctor failed"}
    return 1
  fi
  if echo "$_vr" | grep -Eiq 'unavailable|not available|no provider'; then
    VFS_MSG="Hybrid Mount VFS provider is not available"
    return 1
  fi
  VFS_MSG="Hybrid Mount VFS provider is responding"
  return 0
}

# Paths the selected app actually opens. Not the vold runtime/read views.
vfs_virtual_paths() {
  if [ -n "$E_REL" ]; then
    echo "/storage/emulated/0/$E_REL"
    echo "/mnt/user/0/emulated/0/$E_REL"
    case "$E_REL" in
      Android/data/*|Android/obb/*)
        echo "/mnt/androidwritable/0/emulated/0/$E_REL" ;;
    esac
  else
    echo "$E_DST"
  fi
}

entry_vfs_uid() {
  if [ -n "$E_PKG" ]; then
    _u=$(pkg_uid "$E_PKG")
    if [ -n "$_u" ] && [ "$_u" != "0" ]; then
      echo "$_u"
      return 0
    fi
  fi
  case "$E_UID" in
    ""|0|*[!0-9]*) return 1 ;;
    *) echo "$E_UID"; return 0 ;;
  esac
}

entry_vfs_add() {
  _vu=$(entry_vfs_uid) || {
    say "[!] $E_ID: VFS needs an installed app. Set pkg=<package.name> (UID 0 would redirect every process)."
    return 1
  }
  # at boot the Hybrid Mount provider can come up later than this script
  if [ -n "$UD_BOOT" ] && [ -x "$HM" ]; then
    _w=0
    while ! vfs_ready && [ "$_w" -lt 15 ]; do sleep 2; _w=$((_w + 1)); done
  fi
  vfs_ready || { say "[!] $E_ID: $VFS_MSG"; return 1; }
  _ok=0
  for _d in $(vfs_virtual_paths); do
    for _x in $DST_DENY; do
      [ "$_d" = "$_x" ] && { say "[!] $E_ID: refusing VFS path $_d"; return 11; }
    done
    _r=$("$HM" vfs rule add "$_d" "$E_SRCP" --uid "$_vu" 2>&1)
    if [ $? -eq 0 ]; then
      echo "V $_d $_vu" >> "$_sf"
      _ok=1
      say "[+] $E_ID: vfs $E_SRCP => $_d (uid $_vu${E_PKG:+, $E_PKG})"
    else
      _log "$E_ID: vfs rule for $_d failed: $_r"
      say "[!] $E_ID: vfs $_d failed: $_r"
    fi
  done
  [ "$_ok" -eq 1 ] && boot_id > "$_sf.boot"
  [ "$_ok" -eq 1 ]
}

entry_test_vfs() {
  _vp=$(vfs_virtual_paths | head -n 1)
  _vu=$(entry_vfs_uid)
  _tn=.ud_rw_test_$$
  _st=ok
  _msg="The selected app can read and write folder A through folder B"
  _det=""
  _add() { _det="$_det
detail=$*"; }
  _add "folder A : $(ls -dnZ "$E_SRCP" 2>/dev/null || ls -dn "$E_SRCP" 2>/dev/null)"
  _add "app path : $_vp"
  _add "package  : ${E_PKG:-"(uid only)"} uid ${_vu:-unknown}"
  if [ -z "$_vu" ]; then
    echo "status=fail"
    echo "msg=No app uid (package not installed?)"
    echo "$_det" | sed '/^$/d'
    return 1
  fi
  rm -rf "$E_SRCP/$_tn" "$E_SRCP/$_tn.d" "$_vp/$_tn" "$_vp/$_tn.d" 2>/dev/null
  _g=1078
  [ "$E_KIND" = "obb" ] && _g=1079
  run_as "$_vu" "$_g" "mkdir '$_vp/$_tn.d' && echo ok > '$_vp/$_tn' && [ \"\$(cat '$_vp/$_tn')\" = ok ]" >/dev/null 2>&1
  _r=$?
  if [ "$_r" -eq 99 ]; then
    _st=warn
    _msg="VFS rule is installed, but this shell cannot switch to uid $_vu to test it"
    _add "test     : no setpriv/su uid support"
  elif [ -f "$E_SRCP/$_tn" ] && [ "$(cat "$E_SRCP/$_tn" 2>/dev/null)" = "ok" ]; then
    _add "app uid $_vu: write on $_vp landed in folder A"
  elif [ -e "$_vp/$_tn" ] || [ -d "$_vp/$_tn.d" ]; then
    _st=fail
    _msg="The app wrote the original folder B. The VFS rule did not redirect this uid."
    _add "app uid $_vu: file appeared on $_vp, not in $E_SRCP"
  elif [ "$_r" -ne 0 ]; then
    _st=fail
    _msg="App uid $_vu could not write. Check that the app is installed and folder A is writable by it."
    _add "app uid $_vu: create on $_vp failed"
  else
    _st=warn
    _msg="Write returned success but the test file was not found in folder A"
  fi
  rm -rf "$E_SRCP/$_tn" "$E_SRCP/$_tn.d" "$_vp/$_tn" "$_vp/$_tn.d" 2>/dev/null
  echo "status=$_st"
  echo "msg=$_msg"
  echo "$_det" | sed '/^$/d'
}

entry_umount() { # <id> <force>
  entry_get "$1" || { say "[!] no folder mount named '$1'"; return 1; }
  _sf=$(entry_statefile "$1")
  [ -f "$_sf" ] || { return 0; }
  _bad=0
  for _line in $(sed -e 's/ /|/g' "$_sf" | sed '1!G;h;$!d'); do
    _k=${_line%%|*}; _rest=${_line#*|}
    case "$_k" in
      M) umount_one "$_rest" "$2" || { _bad=1; say "[!] busy: $_rest"; } ;;
      V) _vp=${_rest%|*}; _vu=${_rest##*|}
         if [ "$_vu" != "0" ]; then "$HM" vfs rule del "$_vp" --uid "$_vu" >/dev/null 2>&1; else "$HM" vfs rule del "$_vp" >/dev/null 2>&1; fi ;;
    esac
  done
  if [ $_bad -eq 0 ]; then
    rm -f "$_sf" "$_sf.boot"
    say "[+] $1 unmounted"
    [ "$E_STOP" = "1" ] && [ -n "$E_PKG" ] && am force-stop "$E_PKG" 2>/dev/null
    return 0
  fi
  return 5
}

each_entry() { # <fn> [args...] ; calls fn <id> args for every entry id
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

bind_umount_all() { # <force>
  [ -f "$BINDCONF" ] || return 0
  for _i in $(while read -r _a _rest; do case "$_a" in ""|\#*) ;; *) echo "$_a" ;; esac; done < "$BINDCONF"); do
    entry_umount "$_i" "$1" >/dev/null 2>&1
  done
  return 0
}

entries_count() { # sets S_ENT_TOTAL S_ENT_MOUNTED
  S_ENT_TOTAL=0; S_ENT_MOUNTED=0
  [ -f "$BINDCONF" ] || return 0
  while read -r _a _rest; do
    case "$_a" in ""|\#*) continue ;; esac
    S_ENT_TOTAL=$((S_ENT_TOTAL + 1))
    [ "$(entry_state "$_a")" = "mounted" ] && S_ENT_MOUNTED=$((S_ENT_MOUNTED + 1))
  done < "$BINDCONF"
}

# validate source, destination and options (shared by add and edit); prints the reason on failure
bind_validate() { # <src> <dst> [opts...]
  _vs=$1; _vd=$2; shift 2
  valid_path "$_vs" || { echo "bad source path"; return 2; }
  valid_path "$_vd" || { echo "bad destination path"; return 2; }
  for _x in $DST_DENY; do [ "$_vd" = "$_x" ] && { echo "refusing destination $_vd"; return 11; }; done
  for _o in "$@"; do
    case "$_o" in
      mode=bind|mode=vfs|mode=auto|owner=none|owner=auto|auto=0|auto=1|stop=0|stop=1) ;;
      owner=[0-9]*:[0-9]*|uid=[0-9]*) case "${_o#*=}" in *[!0-9:]*) echo "bad option $_o"; return 2 ;; esac ;;
      pkg=*) valid_pkg "${_o#pkg=}" || { echo "bad package name '${_o#pkg=}'"; return 2; } ;;
      *) echo "bad option $_o"; return 2 ;;
    esac
  done
  return 0
}

# bind_edit <id> <src> <dst> [opts...]: rewrite one line of binds.conf; remounts it if it was mounted
bind_edit() {
  _be_id=$1; _be_s=$2; _be_d=$3; shift 3
  _be_new="$_be_id $_be_s $_be_d $*"
  entry_get "$_be_id" || { echo "no folder mount named '$_be_id'"; return 1; }
  _be_was=$(entry_state "$_be_id")
  if [ "$_be_was" = "mounted" ]; then
    entry_umount "$_be_id" 0 >/dev/null 2>&1 || { echo "'$_be_id' is in use; unmount it (or force) before editing"; return 5; }
  fi
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

# entry_fixwrite <id>: make folder A group-writable for Android's media daemon (group media_rw 1023)
entry_fixwrite() {
  entry_get "$1" || { echo "no folder mount named '$1'"; return 1; }
  [ -d "$E_SRCP" ] || { echo "source folder $E_SRCP does not exist"; return 1; }
  find "$E_SRCP" -xdev ! -type l -exec chgrp 1023 {} + 2>&1 | tail -n 3
  find "$E_SRCP" -xdev ! -type l -exec chmod g+rwX {} + 2>&1 | tail -n 3
  find "$E_SRCP" -xdev -type d -exec chmod g+s {} + 2>&1 | tail -n 3
  say "[+] $E_ID: $E_SRCP is now group media_rw (1023), group-writable, setgid"
}

# entry_test <id>: write/read/mkdir test at a folder mount.
# Prints status=ok|warn|fail|off, msg=<one line> and detail=<line> rows.
entry_test() {
  entry_get "$1" || { echo "status=off"; echo "msg=no such folder mount"; return 1; }
  if [ "$(entry_state "$E_ID")" != "mounted" ]; then echo "status=off"; echo "msg=Not mounted"; return 0; fi
  [ "$E_MODE" = "vfs" ] && { entry_test_vfs; return; }
  _dst=$(entry_dsts | head -n 1)
  _tn=.ud_rw_test_$$
  _st=ok; _msg="Read and write work (as root and as the Android media daemon)"
  _det=""
  _add() { _det="$_det
detail=$*"; }
  _add "folder A : $(ls -dnZ "$E_SRCP" 2>/dev/null || ls -dn "$E_SRCP" 2>/dev/null)"
  _add "folder B : $(ls -dnZ "$_dst" 2>/dev/null || ls -dn "$_dst" 2>/dev/null)"
  _lbl=$(ls -dZ "$_dst" 2>/dev/null)

  # 1. read-only mount?
  if mnt_find "$_dst"; then
    case ",$MI_OPTS," in *,ro,*) _st=fail; _msg="Mounted read-only"; _add "mount options: $MI_OPTS" ;; esac
  fi

  # 2. root: create folder + file, read it back
  _rootok=0
  if [ "$_st" = ok ]; then
    if mkdir "$_dst/$_tn.d" 2>/dev/null && echo ok > "$_dst/$_tn" 2>/dev/null && [ "$(cat "$_dst/$_tn" 2>/dev/null)" = ok ]; then
      _rootok=1; _add "root       : create folder + file + read back: ok"
    else
      _st=fail; _msg="Even root cannot write here (read-only or full filesystem, or source missing)"
      _add "root       : write FAILED ($(df -k "$_dst" 2>/dev/null | tail -n 1))"
    fi
  fi

  # 3. Android media daemon identity (what writes files for /sdcard apps)
  if [ "$_rootok" = 1 ]; then
    _muid=$(pkg_uid com.google.android.providers.media.module); [ -z "$_muid" ] && _muid=$(pkg_uid com.android.providers.media.module); [ -z "$_muid" ] && _muid=10234
    rm -rf "$_dst/$_tn.d" "$_dst/$_tn" 2>/dev/null
    run_as "$_muid" 1023 "mkdir '$_dst/$_tn.d' && echo ok > '$_dst/$_tn' && [ \"\$(cat '$_dst/$_tn')\" = ok ]" >/dev/null 2>&1
    _r=$?
    if [ $_r -eq 99 ]; then
      _st=warn; _msg="Root works; could not test as the media daemon (no setpriv/su uid support)"
    elif [ $_r -ne 0 ]; then
      _st=fail
      _avc=$(logcat -d -b all -t 4000 2>/dev/null | grep -E "avc: +denied" | grep -E "media_rw_data_file|unlabeled" | tail -n 3)
      [ -z "$_avc" ] && _avc=$(dmesg 2>/dev/null | grep -E "avc: +denied" | grep -E "media_rw_data_file|unlabeled" | tail -n 3)
      if [ -n "$_avc" ]; then
        _msg="Blocked by SELinux: the media daemon is denied on this folder (see details)"
        _add "avc denials: $(echo "$_avc" | tr '\n' ' ')"
      else
        _msg="Blocked by file permissions: the media daemon (uid $_muid, group media_rw) cannot write in folder A. No SELinux denial seen"
      fi
      _add "as uid $_muid gid 1023: create folder/file FAILED"
    else
      _add "media daemon (uid $_muid, gid 1023): create folder + file + read back: ok"
    fi
    rm -rf "$_dst/$_tn.d" "$_dst/$_tn" 2>/dev/null
  fi

  # 4. label sanity
  if [ -n "$_lbl" ]; then
    case "$_lbl" in
      *media_rw_data_file*|\?*) ;;
      *) [ "$_st" = ok ] && { _st=warn; _msg="Works, but folder has an unexpected SELinux label (apps may be denied)"; }
         _add "SELinux label: $_lbl (expected media_rw_data_file)" ;;
    esac
  fi

  # 5. do apps see the bind? (a file made behind Android's back must show up in /storage/emulated/0/<B>)
  if [ "$_st" = ok ] && [ -n "$E_REL" ] && [ -d "/storage/emulated/0/$E_REL" ]; then
    echo ok > "$_dst/$_tn" 2>/dev/null
    if [ ! -e "/storage/emulated/0/$E_REL/$_tn" ]; then
      _st=warn; _msg="Writable, but apps do not see changes yet (use Reset media provider)"
      _add "app view : /storage/emulated/0/$E_REL does not show a file created in the bind"
    fi
    rm -f "$_dst/$_tn" 2>/dev/null
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
        entry_get "$_a" && echo "entry=$E_ID|$(entry_state "$E_ID")|$E_MODE|$E_AUTO|$E_SRC|$E_DST|$E_OWNER|$E_STOP|${E_PKG:-}"
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
    vfs-test)
      valid_id "$1" || { echo "status=off"; echo "msg=bad id"; return 2; }
      entry_get "$1" || { echo "status=off"; echo "msg=no such folder mount"; return 1; }
      if [ "$(entry_state "$1")" != "mounted" ]; then echo "status=off"; echo "msg=Not mounted"; return 0; fi
      entry_test_vfs ;;
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
    vfs-check)
      # `vfs doctor` can exit 0 while the provider is down, so use vfs_ready
      vfs_ready; _r=$?
      echo "$VFS_MSG"
      return $_r ;;
    packages)
      # list installed packages with their uid (for the VFS picker)
      _filt=${1:-""}
      pm list packages -U 2>/dev/null | { if [ -n "$_filt" ]; then grep -iF -- "$_filt"; else cat; fi; } | while IFS= read -r _line; do
        case "$_line" in package:*) ;; *) continue ;; esac
        _pkg=${_line#package:}; _pkg=${_pkg%% *}
        _uid=""
        case "$_line" in *" uid:"*) _uid=${_line##* uid:}; _uid=${_uid%% *} ;; esac
        [ -n "$_uid" ] || _uid=$(pkg_uid "$_pkg")
        echo "pkg=$_pkg|uid=${_uid:-?}"
      done ;;
    *) echo "usage: bind list | add|edit <id> <src> <dst> [opts] | test <id> | vfs-test <id> | fixwrite <id> | del <id> | mount <id|all> | umount <id|all> [force] | vfs-check | packages [filter]"; return 2 ;;
  esac
}

# ------------------------------------------------------------------------------
# Other actions
# ------------------------------------------------------------------------------
# Make files reachable for Android's media daemon (gid media_rw = 1023). The share root is setgid
# media_rw, so the daemon is in the *group* class of every file: the "other" bits do not apply to it.
fx() { find "$TARGET" -xdev ! -type l -exec "$@" {} + 2>&1 | tail -n 3; }
cmd_fixperms() {
  load_conf
  _lvl=${1:-read}
  case "$_lvl" in read|rw) ;; *) echo "usage: fixperms read|rw"; return 2 ;; esac
  if ! mounted_ours; then
    echo "Mount the partition first."
    return 1
  fi
  say "[-] fixperms $_lvl on $TARGET: group -> media_rw (1023); group bits +$( [ "$_lvl" = rw ] && echo rwX || echo rX ); directories setgid. Owners are not changed; symlinks are skipped."
  fx chgrp 1023
  if [ "$_lvl" = "rw" ]; then fx chmod g+rwX; else fx chmod g+rX; fi
  find "$TARGET" -xdev -type d -exec chmod g+s {} + 2>&1 | tail -n 3
  chown 1023:1023 "$TARGET" 2>/dev/null
  chmod 2775 "$TARGET" 2>/dev/null
  say "[+] Done. For permanent sharing (new files too) run ubuntu/setup-sharing.sh inside Ubuntu."
}

run_as() { # <uid> <gid> <sh command>
  if command -v setpriv >/dev/null 2>&1; then
    setpriv --reuid "$1" --regid "$2" --clear-groups sh -c "$3"
  elif su "$1" -c true >/dev/null 2>&1; then
    su "$1" -c "$3"
  else
    return 99
  fi
}

cmd_access() {
  load_conf
  mounted_ours || { echo "Mount the partition first."; return 1; }
  echo "label    : $(cat "$DATA_DIR/mount_mode" 2>/dev/null || echo unknown)  (ctx/fsctx = SELinux labelled, plain = not)"
  echo "root dir : $(ls -ldnZ "$TARGET" 2>/dev/null || ls -ldn "$TARGET")"
  echo "-- top-level entries (mode uid gid name) --"
  ls -ln "$TARGET" 2>/dev/null | head -n 15
  echo "-- as the Android media daemon (uid 10234, gid 1023 media_rw) --"
  run_as 10234 1023 "ls '$TARGET' >/dev/null 2>&1 && echo 'list root : ok' || echo 'list root : DENIED'"
  _r=$?
  if [ $_r -eq 99 ]; then echo "(cannot switch uid here: no setpriv/su uid support)"; return 0; fi
  run_as 10234 1023 "find '$TARGET' -xdev -type f 2>/dev/null | head -n 300 | { n=0; bad=0; while read -r f; do n=\$((n+1)); [ -r \"\$f\" ] || bad=\$((bad+1)); done; echo \"files read : \$bad of \$n sampled are NOT readable\"; }"
  run_as 10234 1023 "find '$TARGET' -xdev -type d 2>&1 >/dev/null | grep -c 'Permission denied' | sed 's/^/dirs denied: /'"
  run_as 10234 1023 "touch '$TARGET/.ud_write_test' 2>/dev/null && { echo 'write root: ok'; rm -f '$TARGET/.ud_write_test'; } || echo 'write root: DENIED'"
  echo "-- what apps see (Android storage view of /sdcard/$MOUNT_NAME) --"
  echo "view     : $(android_view)  (ok = same files as the partition, missing = apps cannot see it)"
  for _root in /storage/emulated/0 /mnt/user/0/emulated/0; do
    [ -d "$_root/Android" ] && { ls -A "$_root/$MOUNT_NAME" 2>&1 | head -n 5 | sed "s#^#  $_root/$MOUNT_NAME: #"; break; }
  done
  echo "Fix with: fixperms rw, fixview   (and run ubuntu/setup-sharing.sh inside Ubuntu)"
}

cmd_layout() {
  load_conf
  echo "config  : DEV=$DEV_CFG PART_NAME=$PART_NAME"
  echo "layout  : ${LAYOUT:-n/a}"
  echo "device  : ${DEV_REAL:-none} $( [ -b "$DEV_REAL" ] && echo '(exists)' || echo '(missing)')"
}

cmd_fsck() {
  load_conf
  if dev_in_use; then
    echo "$DEV_REAL is mounted; unmount it (and stop Ubuntu) first."
    return 5
  fi
  if ! command -v e2fsck >/dev/null 2>&1; then
    echo "e2fsck not found on this device. Run it from Ubuntu: e2fsck -p -f $DEV_REAL"
    return 1
  fi
  say "[-] e2fsck -p -f $DEV_REAL"
  e2fsck -p -f "$DEV_REAL" 2>&1 | tail -n 20
  _r=$?
  clr_err
  return $_r
}

cmd_restart_media() {
  say "[-] Restarting MediaProvider so /sdcard re-reads the mount"
  am force-stop com.google.android.providers.media.module 2>/dev/null
  am force-stop com.android.providers.media.module 2>/dev/null
  am force-stop com.android.providers.media 2>/dev/null
  say "[+] Done; reopen your file manager"
}

# Kick MediaProvider awake (it is stopped by restart-media) so its FUSE daemon remounts.
wake_media() {
  content query --uri content://media/external/file --projection _id >/dev/null 2>&1
}

# Wait until Android's own storage view (what apps see) lists the same files as the partition.
# Restarts MediaProvider when it does not, because its FUSE daemon caches the empty
# folder that existed before the mount.
ensure_android_view() {
  [ "$(android_view)" = "missing" ] || return 0
  say "[~] $SDPATH does not show the mount to apps yet; restarting MediaProvider"
  cmd_restart_media >/dev/null 2>&1
  _i=0
  while [ $_i -lt 6 ]; do
    sleep 3
    wake_media
    if [ "$(android_view)" != "missing" ]; then
      say "[+] Apps can see the mount in $SDPATH now"
      return 0
    fi
    _i=$((_i + 1))
  done
  say "[!] Still not visible to apps. Run: ubuntu-data.sh diag  and  ubuntu-data.sh access  and check mount.log"
  return 1
}

cmd_fixview() {
  load_conf
  mounted_ours || { echo "Mount the partition first."; return 1; }
  mount_runtime_views
  say "[-] Restarting MediaProvider..."
  cmd_restart_media >/dev/null 2>&1
  _i=0
  while [ $_i -lt 6 ]; do
    sleep 3
    wake_media
    [ "$(android_view)" != "missing" ] && { say "[+] Apps can see the mount in $SDPATH now"; return 0; }
    _i=$((_i + 1))
  done
  say "[!] Still not visible to apps (view=$(android_view)). Run diag and access."
  return 1
}

cmd_diag() {
  load_conf
  echo "== config =="; echo "DEV=$DEV_CFG -> $DEV_REAL ($DEV_MM) PARTNAME=$DEV_PARTNAME"; echo "layout: ${LAYOUT:-n/a}"; echo "label mode: $(cat "$DATA_DIR/mount_mode" 2>/dev/null)"; echo "TARGET=$TARGET AUTOMOUNT=$AUTOMOUNT"
  echo "== block =="; ls -l "$DEV_REAL" 2>&1
  echo "== superblock =="; echo "luks=$(rd 6 0) ext4magic=$(rd 2 540) f2fs=$(rd 4 256) incompat=$(rd 4 280)"
  command -v blkid >/dev/null 2>&1 && blkid "$DEV_REAL" 2>&1
  echo "== android =="; echo "boot_completed=$(getprop sys.boot_completed) ce_available=$(getprop sys.user.0.ce_available) selinux=$(getenforce 2>/dev/null)"
  echo "== hybrid mount vfs =="; if vfs_ready; then echo "$VFS_MSG"; else echo "unavailable: $VFS_MSG"; fi
  echo "== mounts =="; grep -E "$DEV_BASE| $TARGET " /proc/self/mountinfo 2>/dev/null
  echo "== target =="; ls -ldZ "$TARGET" 2>&1; ls -A "$TARGET" 2>&1 | head -n 10
  echo "== android view =="; echo "view=$(android_view)"; ls -ldZ /storage/emulated/0/$MOUNT_NAME 2>&1
  echo "== namespaces =="; echo "self=$(readlink /proc/self/ns/mnt) init=$(readlink /proc/1/ns/mnt 2>&1)"
  echo "== log tail =="; tail -n 25 "$LOG" 2>/dev/null
}

cmd_set() {
  case "$1" in AUTOMOUNT|FIX_ROOT_PERMS|DISABLE_DATA_MOUNT) ;; *) echo "unsupported key"; return 2 ;; esac
  case "$2" in 0|1) ;; *) echo "value must be 0 or 1"; return 2 ;; esac
  conf_put "$1" "$2"
  echo "$1=$2"
  if [ "$1" = "DISABLE_DATA_MOUNT" ] && [ "$2" = "1" ] && mounted_ours; then
    echo "note: the partition is still mounted; unmount it for the change to take effect"
  fi
}

# ---- folder picker helpers (read-only listing + create) ----
cmd_browse() { # <abs dir> : prints cwd=, err= or dir=<name> lines
  _bp=${1:-/}
  case "$_bp" in /*) ;; *) echo "err=path must be absolute"; return 2 ;; esac
  valid_path "$_bp" || { echo "err=invalid path"; return 2; }
  case "$_bp" in *@*) echo "err=invalid path"; return 2 ;; esac
  [ -d "$_bp" ] || { echo "err=not a folder"; return 1; }
  echo "cwd=$_bp"
  _n=0
  ls -1A "$_bp" 2>/dev/null | while IFS= read -r _e; do
    [ -d "$_bp/$_e" ] || continue
    echo "dir=$_e"
  done | head -n 500
  return 0
}

cmd_mkdir() { # <abs dir> : only inside the partition or internal storage
  _mp=$1
  valid_path "$_mp" || { echo "invalid path"; return 2; }
  case "$_mp" in /*) ;; *) echo "path must be absolute"; return 2 ;; esac
  case "$_mp" in
    "$TARGET"/*) _own=1 ;;
    "$SD_BASE"/Android/*) _own=0 ;;
    "$SD_BASE"/*) _own=1 ;;
    *) echo "refusing: folders can only be created in the Ubuntu partition or internal storage"; return 11 ;;
  esac
  [ -d "$_mp" ] && { echo "exists"; return 0; }
  mkdir -p "$_mp" 2>/dev/null || { echo "could not create folder"; return 1; }
  if [ "$_own" = "1" ]; then chown 1023:1023 "$_mp" 2>/dev/null; chmod 2775 "$_mp" 2>/dev/null; fi
  echo "created"
}

cmd_log() {
  tail -n "${1:-60}" "$LOG" 2>/dev/null
}

# ------------------------------------------------------------------------------
# Partition name (/dev/block/by-name/<name>)
# ------------------------------------------------------------------------------
# pt_check <name>: is there a usable ext4 partition with that name? Prints status= msg= device= partname=.
# Returns 0 ok, 2 bad name, 4 absent, 11 refused (protected), 12 not ext4 / encrypted.
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
    echo "msg=${PF_WARN:-found $DEV_REAL (ext4)}"
    return 0
  fi
  echo "status=fail"
  echo "msg=$PF_MSG"
  [ $_ptr -eq 10 ] && return 4
  return $_ptr
}

# switch to another partition name: test, unmount the old one, save, mount the new one (rolls back on failure)
pt_apply() { # <name> <force 0|1>
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
    0|13|14) return $_pa_rc ;;   # 13: locked, 14: mount disabled; the new name is kept
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

# ------------------------------------------------------------------------------
# Boot + live description
# ------------------------------------------------------------------------------
cmd_boot_mount() {
  load_conf
  UD_BOOT=1; export UD_BOOT
  _log "=== boot-mount === DEV=$DEV_REAL boot_completed=$(getprop sys.boot_completed) ce=$(getprop sys.user.0.ce_available) sd_base_exists=$([ -d "$SD_BASE" ] && echo yes || echo no)"
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

write_desc() { # <text>
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
    if [ -n "$_p" ] && [ "$_p" != "$$" ] && kill -0 "$_p" 2>/dev/null \
       && tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -q 'ubuntu-data.sh.*daemon'; then
      exit 0
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
    browse)        cmd_browse "$1"; exit $? ;;
    mkdir)         cmd_mkdir "$1"; exit $? ;;
    fixperms)      cmd_fixperms "$1" ;;
    access)        cmd_access ;;
    layout)        cmd_layout ;;
    fsck)          cmd_fsck ;;
    restart-media) cmd_restart_media ;;
    fixview)       cmd_fixview; exit $? ;;
    diag)          cmd_diag ;;
    log)           cmd_log "$1" ;;
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
