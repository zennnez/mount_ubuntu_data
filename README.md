# Mount Ubuntu Data (KernelSU / Magisk)

> [!WARNING]
> This module is created for [Ubuntu Linux](https://github.com/TheMojoMan/oneplus-erhai-ubuntu) on **OnePlus Pad 3 only**.
> Flashing on other devices may cause hard brick.

Mounts the Ubuntu data partition (ext4) at `/data/media/0/ubuntu`, which Android shows as
**`/sdcard/ubuntu`**. Ubuntu uses the same partition as **`/data`**, so both systems see the same files.

**The partition is found by name:** `/dev/block/by-name/data` (also tried: `/dev/block/bootdevice/by-name/data`).
Change the name in the WebUI **Partition** box (or `ubuntu-data.sh partition set <name>`): the module checks that the
partition exists and is ext4, unmounts the current one, saves the new name and mounts the new one right away. If the new one
cannot be mounted it goes back to the old one. A name that does not exist, is not ext4, is LUKS, or is a protected system
partition (userdata, metadata, boot, ...) is refused and nothing changes. Set `DEV=/dev/block/sdaNN` in `config.sh` to bypass
the name lookup. If the partition does not exist, the module does nothing.
`ubuntu-data.sh layout` (or the WebUI row "Detected as") shows what the name resolves to.

## Does Android encryption encrypt this partition?

No. Android's file-based encryption (FBE) and metadata encryption only cover the
**userdata** partition. A separate partition such as the Ubuntu partition is never touched by them, so the
files on it are stored in plain text. Two consequences:

* **Anyone with physical access can read that partition**, since it is not protected by your lock screen.
* The mount point `/data/media/0/ubuntu` is a folder *inside* encrypted userdata. It cannot be
  created or mounted until you have unlocked the device once after boot. The old module tried at
  `post-fs-data`, before that, so it silently failed. This version waits for the first unlock.

The module refuses to mount if it finds a LUKS header or a non-ext4 filesystem on the device.
It also refuses protected system partitions (userdata, metadata, persist, boot, ...) and Android's own `/data`.

## Install

Flash the zip in the KernelSU or Magisk app and reboot. Nothing happens if the partition does not exist.
The partition must already contain an ext4 filesystem, for example:

    mkfs.ext4 -L ubuntu-data /dev/block/sda18      # erases it! (use the device `layout` shows)

## Use

* **Live status:** the module description in the manager shows the current state
  (🟢 mounted + usage, 🔴 unmounted, ⏳ waiting for unlock, ⚪ partition missing, 🟠 error).
* **WebUI** (KernelSU manager, or WebUI X / KsuWebUI for Magisk): status, Mount/Unmount button,
  auto-mount switch, filesystem check, permission fix, diagnostics and log.
* **Action button** in the manager toggles mount/unmount and prints the status.
* **Terminal:** `su -c 'sh /data/adb/modules/mount_ubuntu_data/ubuntu-data.sh <cmd>'`
  with `status | info | mount | umount [force] | toggle | fixperms | fsck | restart-media | diag | log`.

## Ubuntu side (`/data`)

Ubuntu must mount the same partition at `/data`. How depends on how Ubuntu runs:

* **Native boot:** add to `/etc/fstab`
  `/dev/sda18  /data  ext4  defaults,noatime  0  2` (or use `UUID=` from `blkid`).
  Android must not have it mounted at the same time. Unmount first, or boot Ubuntu separately.
* **Chroot / container on Android:** bind the Android mount into the rootfs. Either add
  `/data/media/0/ubuntu → /data` to your container's bind-mount settings, or let this module do it:
  in `/data/adb/mount_ubuntu_data/config.sh` set
  `EXTRA_BINDS="@:/path/to/ubuntu-rootfs/data"` (`@` is the mounted partition). Start the container
  after the mount exists. A container that is already running will not see a later mount.

## Access without root (file permissions)

**Why files are unreadable.** ext4 stores real owners and modes. Android's storage layer (the media provider
that serves `/sdcard` to apps) is not root: it runs as an app uid with group `media_rw` (gid 1023). Files Ubuntu
creates as `root:root 0600`, or inside `0700` home folders, are therefore closed to it.
The module makes the partition root `1023:1023`, mode `2775` (setgid), so new files inherit group `media_rw`.
That makes the daemon fall into the *group* class of every file: **the "other" bits no longer apply to it**,
so `chmod o+r` does not help. Group bits and ACLs do.

Fixes, from quickest to permanent:

1. **Android side, one-off:** WebUI **Make readable** / **Make writable** (or `ubuntu-data.sh fixperms read|rw`).
   Recursive, symlink-safe, keeps owners; sets the group to `media_rw` and adds `g+rX` (read) or `g+rwX` (rw).
   Files that Ubuntu creates later with a strict umask need it again.
2. **Ubuntu side, permanent (recommended):** run once inside Ubuntu as root
   `sh /data/.ubuntu-data-tools/setup-sharing.sh` (the module publishes it there; `-u user` selects users, `-m` the mountpoint).
   It creates group `media_rw` (1023), adds your user, and grants that group rwX through POSIX ACLs including a **default ACL**,
   so files created later, even by root with `umask 077`, stay accessible. Other Ubuntu users and other Android apps get nothing.
3. **Extracted archives (the common trap):** an archive carries its own modes, usually `0700`/`0600`, and `tar -x` as root also
   restores its owner and group. That skips the setgid group inheritance and the umask, and the `chmod` to `0700` sets the ACL
   mask to `---`, which switches off every ACL entry, including the `media_rw` one from `setup-sharing.sh`. The folder looks
   normal in Ubuntu, but Android cannot open it (it may even be missing from the storage view). Plain files you create
   yourself keep working, which is why this is easy to miss. No `tar`/`unzip` option widens the modes stored in the archive, so repair it after extracting:
   * Ubuntu: `share-fix /data/<folder>` (the command `setup-sharing.sh` installs; it only touches that folder and tests it as the Android media daemon), or
   * Android: WebUI **Make writable**, CLI `ubuntu-data.sh fixperms rw [folder]`, or
   * automatic: switch on **Auto-fix permissions on mount** (`AUTOFIX_PERMS=1`): it runs once after every mount (boot and manual). Off by default (see below).
4. **Plain umask:** in Ubuntu use `umask 002` and put your user in group 1023; new files are then group-writable by default.

**Check it:** WebUI **Access test** (or `ubuntu-data.sh access`) runs the checks as uid 10234 / gid 1023, the identity of the
Android media daemon, and lists what is unreadable.
Files written from Android are owned by the media provider's uid with group `media_rw`; your Ubuntu user can edit them
once it is in that group.

Privacy note: anything you make readable here is readable by apps with "All files access" and by group `media_rw` members.
Keep secrets (ssh keys, tokens) on a different folder or partition if that matters. Do not use `chmod -R o+r`: it opens files to every Ubuntu user.

**SELinux.** The partition is mounted with the label `media_rw_data_file` (three fallbacks: `context=`, then
`fscontext=`+`defcontext=`, then plain). If it ends up plain, the status shows a warning and the included
`sepolicy.rule` (media provider may access unlabeled files, nothing else) is the safety net; reboot after installing.

## Folder mounts (folder A inside folder B)

Mount any folder onto any other, for example a folder of the Ubuntu partition as a game's data folder.
Manage them in the WebUI ("Folder mounts", folders are chosen with a folder picker) or in `/data/adb/mount_ubuntu_data/binds.conf`:

    # id    A (source)              B (destination)                         options
    game1   @/games/mygame          Android/data/com.example.game/files    owner=auto stop=1

* **A:** `@` or `@/sub/dir` is the mounted partition; otherwise an absolute path.
* **B:** a relative path (or `/sdcard/...`) is inside internal storage. The module mounts it on the real
  storage path *and* on the lower-filesystem views Android builds app storage from
  (`/mnt/androidwritable/...`, `/mnt/pass_through/...`), because that is where an app's own
  `Android/data/<package>` is bound from. An absolute path is mounted as given, anywhere except a small deny-list
  (`/`, `/data`, `/data/adb`, `/system`, ...).
* **Options:** `mode=bind|vfs` (default `bind`), `owner=none|auto|UID:GID`, `auto=0|1` (mount at boot),
  `stop=0|1` (force-stop the app on mount/unmount), `pkg=<package>` (required for `mode=vfs`), `uid=N` (VFS only).
  An old `mode=auto` line is read as `vfs` when it has `pkg=`/`uid=`, otherwise as `bind`.
* **`owner=auto`:** for `Android/data/<pkg>` or `Android/obb/<pkg>` the app's uid is also granted write access (the top of folder A is chowned to the app; existing files stay owned by the Ubuntu user and get other-write). Folder mounts are plain bind mounts (`mount --bind`), nothing is forced. If an app cannot write, tap the status mark of the folder mount: after a permission failure it offers `bind fixwrite <id>` (group `media_rw`, group-writable, setgid). Files you copy in later from Ubuntu must stay group-accessible; use `umask 002` in Ubuntu.
* Mount **before** starting the game, or use `stop=1`. An app that is already running keeps its old view.
* CLI: `ubuntu-data.sh bind list | add <id> <A> <B> [opts] | del <id> | mount <id|all> | umount <id|all> [force]`.
  Unmounting the partition unmounts all folder mounts first.

## Overlayfs, Hybrid Mount and detectability

This module does **not** use overlayfs. It makes a real ext4 mount of the Ubuntu partition and plain bind mounts. They
show up in `/proc/self/mountinfo` of every process that shares the mount namespace, including apps, and
the source is the block device. That is not the usual root-detection signature (overlay/tmpfs on system
partitions), but it is visible.

The Hybrid Mount metamodule maps *module files* onto partitions (OverlayFS, magic mount, or its VFS path
redirect). It cannot mount a partition. Its VFS backend does redirect a path to another without any mount
entry and can be limited to one app uid, so it is the only way here to make a game folder visible to
that one app only. `mode=vfs` uses `hybrid-mount vfs rule add <B> <A> --uid <app uid>` when the metamodule and the kernel
provider (`hybrid-mount vfs doctor`) are present. Treat it as **experimental**: Hybrid Mount documents
redirecting files and `--opaque` directories, and does not document redirecting a whole directory, so check that the
game actually sees the data. `mode=vfs` never falls back to a bind mount.
VFS rules are runtime-only: the module re-applies them on every boot (and waits up to 30 s for the provider to come up).

## Config: `/data/adb/mount_ubuntu_data/config.sh`

| Key | Default | Meaning |
|---|---|---|
| `DEV` | `auto` | block device, or `auto` = `/dev/block/by-name/<PART_NAME>` |
| `PART_NAME` | `data` | partition name under `/dev/block/by-name/` (WebUI: Mount Settings) |
| `PUBLISH_TOOLS` | `1` | copy the Ubuntu helper to `/.ubuntu-data-tools/` on the partition |
| `MOUNT_NAME` | `ubuntu` | folder in internal storage |
| `AUTOMOUNT` | `0` | mount after boot/unlock (off by default; switch it on in the WebUI) |
| `FIX_ROOT_PERMS` | `1` | chown root of partition to media_rw, setgid |
| `AUTOFIX_PERMS` | `0` | `1` = once after every mount (boot-mount and manual mount) fix files Android cannot use (e.g. extracted archives) |
| `DISABLE_DATA_MOUNT` | `0` | `1` = never mount the partition (dual boot Android + Linux option only) |
| `EXTRA_BINDS` | empty | legacy `"src:dst ..."` bind mounts; prefer Folder mounts |

## Troubleshooting

* Mounted (🟢) but empty or missing in file managers: use *Reset media provider* in the WebUI, or reopen the file manager.
  Run *Diagnostics* and check `android view` and the namespaces.
* Mount failed with a journal/dirty error: unmount, stop Ubuntu, run *Check filesystem*.
* Log: `/data/adb/mount_ubuntu_data/mount.log`.
* Unmount says "busy": close Ubuntu and file managers, or use `umount force` (lazy detach).

## Support

Questions, bugs, ideas: Telegram **https://t.me/kokernel** (also linked in the WebUI).

## Dual boot option: disable the partition mount

WebUI switch **Disable /data partition mount** (config key `DISABLE_DATA_MOUNT`, default `0` = off, the partition is mounted
as before). This option is for **dual boot Android + Linux**, to mount the additional `sdaX` partition in both systems.
**Do not use it if you do not dual boot.** When on, the module never mounts the partition (boot, Action button, WebUI
Mount button); folder mounts whose source is an absolute path keep working. Turning it on unmounts the partition first.
CLI: `ubuntu-data.sh set DISABLE_DATA_MOUNT 1|0`.

## Changes in v2.8

* **Fix: a folder extracted in Ubuntu was invisible/unusable in Android even after the fix buttons.** Causes found and handled:
  * `tar`/`unzip` as root leave `0700` modes, a foreign group and an ACL mask of `---` (see *Extracted archives* above).
  * The permission pass at mount runs only once per partition (marker `.android_perms_initialized`), so later extractions
    were never repaired automatically.
  * `setup-sharing.sh` hid its own errors. It now prints them, repairs a single folder (`share-fix /path`), fixes the ACL mask,
    and finishes with a test as the Android media daemon (uid 10234, gid 1023).
* `fixperms read|rw [folder]` now (1) can be limited to one folder, (2) re-tests as the media daemon and reports how many
  folders/files are still blocked, (3) relabels the files `media_rw_data_file` when the partition could not be mounted with a
  forced label, and (4) when a folder is still missing in the Android storage view, restarts MediaProvider once and re-checks.
* **New `inspect [path]` (also part of WebUI "Diagnostics"):** per folder shows owner, mode, SELinux label, whether the media daemon can open it
  (and nested folders), whether Android's storage view lists it, and warns about case clashes (`Docs` + `docs`: Android is
  case-insensitive and shows one), symlinks, hidden/invalid names and recent SELinux denials.
* **New opt-in `AUTOFIX_PERMS=1`** (WebUI switch "Auto-fix permissions on mount", default **off**): once after every successful mount
  (boot-mount, WebUI/Action mount, partition switch) it fixes only entries Android cannot use (group not `media_rw`, folders
  without group rwx + setgid, files without group rw). It runs in the background at lowest priority, at boot only after the
  system has been up for 2 minutes, is stopped before an unmount, skips entries that are already correct, and restarts
  MediaProvider if folders are still missing from Android's view afterwards. It no longer runs on a timer.
* **Folder mounts:** `owner=auto` now fixes the whole of folder A for the app (not just its top folder); the read/write test and the fix use the app's own uid/gid for `Android/data|obb/<pkg>`, and the test also writes through Android's storage view as the app. New option `move=1` ("Move existing files from folder B into folder A") moves what already sits in B onto the partition before the bind.
* **Folder mounts no longer leave stale mounts behind:** after unmounting, and before every bind, any leftover mount from the partition at folder B (and its Android views) is removed, so remounts no longer skip views or stack on top of old mounts. The status-icon test lists how many mounts sit at folder B.
* **Folder-mount test fixed:** for `Android/data|obb/<pkg>` the media daemon (with its groups media_rw, ext_data_rw, ext_obb_rw) is tested on folder A, and the app itself is tested through Android's storage view; apps never open `/data/media` directly. The move option now merges folders that exist on both sides, drops identical duplicates and reports the real error of a failed move.
* WebUI: Mount Settings card (warning, partition name, boot-mount and auto-fix switches, Mount button); Diagnostics includes the
  folder inspection; new **Download log** button (`ubuntu-data.sh log-export`) saves the full log to `/sdcard/Download/`.

## Changes in v2.7

* **Boot fix: the v2.6 forced-read-write code is removed.** v2.6 re-mounted, remounted read-write and sometimes unmounted
  bind mounts at boot (partition views, folder mounts, `EXTRA_BINDS`) and ran recursive permission changes on folder A while
  Android was starting; devices could fail to boot. The partition mount (explicit `rw`, as before) and the folder mounts are
  back to the plain v2.5 behaviour.
* The partition is found as `/dev/block/by-name/<name>` (default `data`) instead of "userdata + 3". New **Partition** box in
  the WebUI: on change it tests that the partition exists and is ext4, then remounts the new one instantly (rollback on failure).
  CLI: `ubuntu-data.sh partition get | test <name> | set <name> [force]`. Existing `config.sh` files get `PART_NAME=data`.
* Hybrid Mount VFS folder mounts (`mode=vfs`) are usable from the WebUI: app package field with a list of installed apps,
  "Auto" method removed, and the read/write test for VFS entries runs as the app uid.
* VFS fixes: rules from an earlier boot were treated as still active, so they were never re-applied after a reboot; the
  provider check now looks at `"responds": true`; boot waits for the provider; `packages` is fast.
* Installing no longer leaves `.gitattributes` in the module; the build script (`pack.py`) refuses CRLF/BOM and writes LF.
* A background permission pass no longer keeps the WebUI/Action output waiting; the log no longer repeats the same line every
  few seconds; stale lock directories are cleared.

## Changes in v2.6 (read-write forcing was removed in v2.7)

* Folder-to-folder mounts are read-write. On Android, `mount --bind` often comes up read-only, so the folder showed up but every write failed. The ext4 mount already passed an explicit `rw` option, which is why `sda18` → `/sdcard/ubuntu` worked. Each folder bind is now created with `rw` and remounted read-write. `/mnt/runtime/read` stays read-only on purpose.
* Mounting a folder also opens it for Android: group `media_rw` (1023), setgid, group `rwX`. If folder B is `Android/data/<package>` or `Android/obb/<package>`, that app can write too, without taking the files away from your Ubuntu user.
* The installer strips Windows CRLF (and a UTF-8 BOM) from the scripts before they run, so a module saved on Windows still flashes instead of dying with a shell syntax error. This zip is Unix LF.

## Changes in v2.5

* Folder mounts: the Method dropdown is disabled (locked to Bind mount) when Hybrid Mount is not available, and re-checked each time the form opens.
* Clearer wording for the "Let the target app read and write folder A" option.
* Each mounted folder mount gets a read/write test with a status mark: green check = OK, yellow ! = works with a warning, red cross = failed.
  Tap the mark for details and a re-test. It writes a folder and a file as root and as the Android media daemon, tells file permissions apart
  from SELinux denials, and checks that apps can see the bind. On a permissions failure it offers to make folder A group-writable
  (`ubuntu-data.sh bind fixwrite <id>`). CLI: `ubuntu-data.sh bind test <id>`.
* Pencil button on every folder mount to edit it (`ubuntu-data.sh bind edit <id> <A> <B> [opts]`); a mounted entry is remounted on save.

## Changes in v2.3

* New switch to disable the partition mount (dual boot only, default off) with a warning.
* Folder mounts: folders A and B are chosen with a folder picker (browse, go up, create a folder) instead of typing paths.
* Telegram support link (https://t.me/kokernel).

## Changes in v2.2

* Partition auto-detection (Android userdata + 3, so sda18 for your layout).
* Access without root: correct group-based fixes (`fixperms read|rw`), `access` test, Ubuntu `setup-sharing.sh` with default ACLs.
* SELinux label fallbacks and a warning when the mount is unlabeled; minimal `sepolicy.rule` safety net.

## Changes in v2.1

* Folder mounts: mount any folder A onto any folder B (see above), bind or Hybrid Mount VFS.

## Changes in v2.0

* Targets `sda17` instead of Android's own `data` partition (which can never be mounted a second time).
* Mounts after first unlock; no more `post-fs-data` mount into locked storage.
* Real ext4/LUKS detection (raw superblock), safety refusals, locking, logs.
* Live description, WebUI, Action toggle, CLI, `EXTRA_BINDS` for the Ubuntu rootfs.
* Standard Magisk/KernelSU installer; the `sepolicy.rule` that opened `unlabeled` files to every app is gone (the mount is labelled `media_rw_data_file` instead).
