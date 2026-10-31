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

Mount any folder onto any other, for example a folder of the Ubuntu partition as a game or app's data folder.
Manage them in the WebUI ("Folder mounts", with a visual folder picker and searchable installed app picker) or in `/data/adb/mount_ubuntu_data/binds.conf`:

    # id    A (source)              B (destination)                         options
    game1   @/games/mygame          Android/data/com.example.game/files    owner=auto stop=1 move=1

* **A (source):** `@` or `@/sub/dir` is inside the mounted partition; otherwise an absolute path.
* **B (destination):** a relative path (or `/sdcard/...`) is inside internal storage. The module mounts it across the primary storage path *and* the lower-filesystem namespace views Android uses for app storage (`/mnt/user/0/...`, `/mnt/androidwritable/...`, `/mnt/pass_through/...`), ensuring apps see the mounted folder seamlessly.
* **Options:**
  * `owner=auto|none|UID:GID` (default `auto`): for `Android/data/<pkg>` or `Android/obb/<pkg>`, ensures the app uid and media groups own and can write to the directory.
  * `move=1` (default 0): automatically moves existing contents from destination B into source A before mounting, preventing files from being hidden or lost.
  * `auto=1` (default 1): automatically mount at boot.
  * `stop=1` (default 0): force-stop the target app on mount/unmount so it immediately reloads the new storage view.
  * `pkg=<package>`: target app package name.
* **Verification & Status:** The WebUI automatically tests read/write access as root and as Android's MediaProvider daemon (showing ✔ for working mounts, ✖ if blocked). Tapping the status icon reveals detailed diagnostics and offers one-click permission repair (`bind fixwrite <id>`).
* **CLI:**
  `ubuntu-data.sh bind list | add <id> <A> <B> [opts] | edit <id> <A> <B> [opts] | test <id> | fixwrite <id> | del <id> | mount <id|all> | umount <id|all> [force] | packages [filter]`

## Mount Mechanism & Detectability

This module uses standard Linux ext4 partition mounting and bind mounts (`mount --bind`) alongside dynamically applied SELinux MLS trust rules (`sepolicy.rule`). It does not use OverlayFS or external redirection hooks. All mounts appear cleanly in `/proc/self/mountinfo` from the underlying block device without modifying Android system partitions.

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
