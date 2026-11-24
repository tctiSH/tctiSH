//! Commands for mounting iOS folders into the tctiSH guest.

use std::{
    fs::{self, OpenOptions},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, anyhow};
use serde::Deserialize;
use sys_mount::{FilesystemType, Mount, MountFlags, UnmountFlags, unmount};

use crate::comms::run_command;

// Don't allow mounting on the host.
#[cfg(target_os = "macos")]
const MOUNT_ALLOWED: bool = false;

#[cfg(target_os = "linux")]
const MOUNT_ALLOWED: bool = true;

/// Fails unless this is running in the guest, the only place mounting works.
fn ensure_mount_allowed() -> Result<()> {
    if MOUNT_ALLOWED {
        Ok(())
    } else {
        Err(anyhow!("mount commands must be run inside the guest!"))
    }
}

/// Where the app's shared folder is mounted, by `mount_shared.sh` at the first
/// root login. A folder the host shares appears there, under the name
/// `prepare_mount` answers with.
const SHARE_ROOT: &str = "/ios_host";

/// The 9p tag the shared folder is mounted from.
const SHARE_TAG: &str = "shared";

/// A lock that `mount_shared.sh` holds while the boot mounts the remembered
/// folders again. `mount` and `forget` wait for it, so they don't clash with
/// the boot.
const RESTORE_LOCK: &str = "/run/lock/tctish-restore";

/// How long `mount` and `forget` wait for that lock, and how often they check.
/// A little longer than the 60 s `mount_shared.sh` allows the restore.
const RESTORE_WAIT: Duration = Duration::from_secs(65);
const RESTORE_POLL: Duration = Duration::from_millis(100);

/// How long the restore waits for each folder. A folder on an offline iOS
/// provider, like a network share whose server is down, can hang for tens of
/// seconds. After this long the restore skips it and moves on. It must be
/// longer than `bind_shared` waits for a new folder to appear (3 s).
const RESTORE_EACH: Duration = Duration::from_secs(5);

/// The cache mode when the host doesn't say: reads go through the page cache,
/// coherent from one open to the next, and writes go straight through. See
/// `assets/overlay/etc/profile.d/mount_shared.sh`.
const FALLBACK_CACHE: &str = "readahead";

/// How long a newly shared folder may take to appear in the guest.
const APPEAR_RETRIES: u32 = 30;
const APPEAR_RETRY_DELAY: Duration = Duration::from_millis(100);

/// Handles the "mount" command: shares the folder the user picked as `name`,
/// and mounts it at `guest_path`. Returns its name under `/ios_host`.
pub(crate) fn mount_from_host(
    host_bookmark: String,
    name: String,
    guest_path: String,
) -> Result<String> {
    ensure_mount_allowed()?;

    check_mountpoint(&guest_path)?;
    let tag = prepare_mount_from_bookmark(host_bookmark, name)
        .context("couldn't get tctiSH ready for the mount")?;
    bind_shared(&tag, &guest_path)?;
    Ok(tag)
}

/// Mounts a host path, rather than a bookmark: what `tctish-mount` did.
pub(crate) fn mount_from_host_path(host_path: String, guest_path: String) -> Result<()> {
    ensure_mount_allowed()?;

    check_mountpoint(&guest_path)?;
    let tag =
        prepare_mount_from_path(host_path).context("couldn't get tctiSH ready for the mount")?;
    bind_shared(&tag, &guest_path)
}

/// If the boot is still mounting the remembered folders, waits for it to
/// finish, so that a mount or a forget doesn't clash with it. Gives up after
/// `RESTORE_WAIT`.
pub(crate) fn wait_for_restore() {
    // Until /ios_host is mounted, the restore can't have started, so there's nothing to wait for.
    if !mount_points().iter().any(|point| point == SHARE_ROOT) {
        return;
    }
    let Ok(file) = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(RESTORE_LOCK)
    else {
        return;
    };

    // Taking a shared lock only works once the restore has let go of it. flock can't wait with a
    // timeout, so try without blocking, and poll. The lock goes when `file` closes.
    // SAFETY: a valid descriptor, which `file` keeps open for each call.
    let try_lock = || unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } == 0;
    if try_lock() {
        return;
    }
    eprintln!("Waiting for tctiSH to finish mounting the remembered folders again...");
    let started = Instant::now();
    while started.elapsed() < RESTORE_WAIT {
        thread::sleep(RESTORE_POLL);
        if try_lock() {
            return;
        }
    }
    eprintln!("It hasn't finished; going ahead.");
}

/// What the app knows about a shared folder name on this disk.
#[derive(Debug, PartialEq)]
pub(crate) enum ShareState {
    /// Remembered, and the guest can reach it, so it can be mounted again
    /// without the picker.
    Reachable,

    /// Remembered, but the folder can't be reached right now.
    Unreachable,

    /// This disk doesn't remember a folder by this name.
    Unknown,
}

/// Asks the app what it knows about the folder shared as `name`.
pub(crate) fn share_state(name: &str) -> Result<ShareState> {
    let response = run_command("share_state".to_owned(), Some(name.to_owned()), None)?;
    Ok(match response.value.as_deref() {
        Some("reachable") => ShareState::Reachable,
        Some("unreachable") => ShareState::Unreachable,
        _ => ShareState::Unknown,
    })
}

/// Mounts a remembered folder at `guest_path` without showing the picker. Only
/// call this when `share_state` says the folder is reachable.
pub(crate) fn mount_remembered(name: &str, guest_path: &str) -> Result<()> {
    ensure_mount_allowed()?;
    bind_shared(name, guest_path)
}

/// Tells the app that `name` is now mounted at `guest_path`, so the next boot
/// mounts it there again.
pub(crate) fn record_mountpoint(name: &str, guest_path: &str) -> Result<()> {
    let mountpoint = fs::canonicalize(guest_path)
        .with_context(|| format!("couldn't find {guest_path}"))?
        .to_string_lossy()
        .into_owned();
    run_command(
        "record_mountpoint".to_owned(),
        Some(name.to_owned()),
        Some(mountpoint),
    )?;
    Ok(())
}

/// A share the app remembers for this disk.
#[derive(Debug, Deserialize)]
struct RememberedShare {
    name: String,
    mountpoints: Vec<String>,
    reachable: bool,
}

/// The shares the app remembers for this disk.
fn remembered_shares() -> Result<Vec<RememberedShare>> {
    let response = run_command("remembered_shares".to_owned(), None, None)?;
    serde_json::from_str(response.value.as_deref().unwrap_or("[]"))
        .context("couldn't read the app's list of remembered folders")
}

/// Mounts every remembered folder again, everywhere it was mounted. Runs at
/// boot, once `/ios_host` is mounted. It never shows the picker: a folder that
/// can't be reached, or whose mountpoint has been deleted, is skipped with a
/// message.
pub(crate) fn restore_remembered(release_lock_fd: Option<i32>) -> Result<()> {
    // Release the boot's lock however this function ends. Don't leave it to the process exiting: a
    // mount stuck on an offline folder can stop the process from exiting.
    let _release = LockRelease(release_lock_fd);
    ensure_mount_allowed()?;

    // Mount shorter paths first, so that a mount inside another one ends up on top of it.
    struct Wanted {
        name: String,
        mountpoint: String,
        reachable: bool,
    }
    let mut wanted: Vec<Wanted> = remembered_shares()?
        .into_iter()
        .flat_map(|share| {
            let (name, reachable) = (share.name, share.reachable);
            share.mountpoints.into_iter().map(move |mountpoint| Wanted {
                name: name.clone(),
                mountpoint,
                reachable,
            })
        })
        .collect();
    wanted.sort_by_key(|want| want.mountpoint.len());

    // Once a folder fails to answer, skip it at its other mountpoints too. Also skip anything
    // mounted inside where it would have gone: if it answered late, that would end up underneath.
    let mut slow_names: Vec<String> = Vec::new();
    let mut slow_points: Vec<String> = Vec::new();

    let mounted = mount_points();
    for Wanted {
        name,
        mountpoint,
        reachable,
    } in wanted
    {
        if mounted.contains(&mountpoint) {
            continue;
        }
        if !reachable {
            eprintln!(
                "tctiSH: the folder shared as '{name}' can't be reached, so {mountpoint} isn't \
                 mounted; `mount -t ios {name} {mountpoint}` asks for it again"
            );
            continue;
        }
        let under_slow = slow_points
            .iter()
            .any(|point| mountpoint.starts_with(&format!("{point}/")));
        if slow_names.contains(&name) || under_slow {
            eprintln!(
                "tctiSH: {mountpoint} isn't mounted, as a folder it depends on didn't answer; \
                 `mount -t ios {name} {mountpoint}` tries again"
            );
            continue;
        }

        match bind_within(&name, &mountpoint, RESTORE_EACH) {
            Some(Restored::Mounted) => eprintln!("tctiSH: mounted '{name}' at {mountpoint} again"),
            Some(Restored::Gone) => {
                eprintln!("tctiSH: {mountpoint} is gone, so '{name}' isn't mounted there again")
            }
            Some(Restored::Failed(err)) => {
                eprintln!("tctiSH: couldn't mount '{name}' at {mountpoint} again: {err:#}")
            }
            None => {
                eprintln!(
                    "tctiSH: the folder shared as '{name}' didn't answer within {}s, so \
                     {mountpoint} isn't mounted; `mount -t ios {name} {mountpoint}` tries again",
                    RESTORE_EACH.as_secs()
                );
                slow_names.push(name);
                slow_points.push(mountpoint);
            }
        }
    }
    Ok(())
}

/// Releases a lock on an inherited file descriptor when dropped.
/// `mount_shared.sh` passes the restore lock on fd 8.
struct LockRelease(Option<i32>);

impl Drop for LockRelease {
    fn drop(&mut self) {
        if let Some(fd) = self.0 {
            // SAFETY: flock on any descriptor number is safe; a bad one only fails.
            unsafe { libc::flock(fd, libc::LOCK_UN) };
        }
    }
}

/// The result of one mount during the restore.
enum Restored {
    Mounted,

    /// The mountpoint was deleted after it was remembered.
    Gone,

    Failed(anyhow::Error),
}

/// Mounts `name` at `mountpoint` on another thread, and waits up to `limit`.
/// Returns `None` if that takes too long. Checking the mountpoint and mounting
/// can both hang on an offline folder. A mount that times out is abandoned: it
/// won't mount even if it finishes later, and its thread is left until its
/// request returns.
fn bind_within(name: &str, mountpoint: &str, limit: Duration) -> Option<Restored> {
    let abandoned = Arc::new(AtomicBool::new(false));
    let (sender, receiver) = mpsc::channel();
    let (name, mountpoint) = (name.to_owned(), mountpoint.to_owned());
    let flag = Arc::clone(&abandoned);
    thread::spawn(move || {
        let restored = if !Path::new(&mountpoint).is_dir() {
            Restored::Gone
        } else {
            match bind_shared_unless(&name, &mountpoint, &flag) {
                Ok(()) => Restored::Mounted,
                Err(err) => Restored::Failed(err),
            }
        };
        let _ = sender.send(restored);
    });

    let restored = receiver.recv_timeout(limit).ok();
    if restored.is_none() {
        abandoned.store(true, Ordering::SeqCst);
    }
    restored
}

/// Prints one line per remembered folder: its name, whether it can be reached,
/// and where the boot mounts it. Fields are separated by tabs, since paths can
/// contain spaces.
pub(crate) fn list_remembered() -> Result<()> {
    for share in remembered_shares()? {
        let state = if share.reachable {
            "reachable"
        } else {
            "can't be reached"
        };
        let points = if share.mountpoints.is_empty() {
            "(mounted nowhere)".to_owned()
        } else {
            share.mountpoints.join("\t")
        };
        println!("{}\t{state}\t{points}", share.name);
    }
    Ok(())
}

/// Unmounts a remembered folder everywhere it's mounted, and tells the app to
/// forget it. After that, the boot no longer mounts it, and `mount -t ios` with
/// the name shows the picker again. If an unmount fails, the app still
/// remembers the folder; any mounts already removed stay removed until the next
/// boot.
pub(crate) fn forget(name: &str) -> Result<()> {
    ensure_mount_allowed()?;
    wait_for_restore();
    if share_state(name)? == ShareState::Unknown {
        return Err(anyhow!("'{name}' isn't a folder this disk remembers"));
    }

    // Unmount the innermost first, so nothing is still mounted inside one being removed.
    let mut points = mounts_of_share(name);
    points.sort_by_key(|point| std::cmp::Reverse(point.len()));
    for point in &points {
        unmount(point, UnmountFlags::empty())
            .with_context(|| format!("couldn't unmount {point}, so '{name}' wasn't forgotten"))?;
    }

    run_command("forget_share".to_owned(), Some(name.to_owned()), None)?;
    Ok(())
}

/// Where `name` is mounted in the guest. These are bind mounts of
/// `/ios_host/<name>`, which `/proc/self/mountinfo` lists with the 9p source
/// `shared` and the root `/<name>`.
fn mounts_of_share(name: &str) -> Vec<String> {
    let mountinfo = fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    let root = format!("/{name}");
    mountinfo
        .lines()
        .filter_map(|line| {
            // The fields before " - " describe the mount; after it come the filesystem type and
            // source.
            let (mount, filesystem) = line.split_once(" - ")?;
            let mut mount = mount.split(' ');
            let (mount_root, point) = (mount.nth(3)?, mount.next()?);
            let mut filesystem = filesystem.split(' ');
            let (kind, source) = (filesystem.next()?, filesystem.next()?);
            (kind == "9p" && source == SHARE_TAG && unescape_mount_path(mount_root) == root)
                .then(|| unescape_mount_path(point))
        })
        .collect()
}

/// Whether the app accepts `name` as a name in the shared folder: up to 64
/// letters, digits, `.`, `_` and `-`, but not `.` or `..`. The same check as
/// `ConfigServer.isShareName`.
pub(crate) fn is_share_name(name: &str) -> bool {
    (1..=64).contains(&name.len())
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
        && name != "."
        && name != ".."
}

/// A name under `/ios_host` for a folder mounted at `mountpoint`: its last
/// component, with anything the host won't accept replaced by `_`.
pub(crate) fn default_name(mountpoint: &str) -> String {
    let last = Path::new(mountpoint)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let name: String = last
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();

    match name.as_str() {
        "" | "." | ".." => "mount".to_owned(),
        _ => name,
    }
}

/// The mount points in `/proc/mounts`, with its octal escapes (`\040` for a
/// space, and so on) undone.
fn mount_points() -> Vec<String> {
    let mounts = fs::read_to_string("/proc/mounts").unwrap_or_default();
    mounts
        .lines()
        .filter_map(|line| line.split(' ').nth(1))
        .map(unescape_mount_path)
        .collect()
}

/// Undoes the octal escapes (`\040` for a space, and so on) in a path from
/// `/proc/mounts` or `/proc/self/mountinfo`.
fn unescape_mount_path(field: &str) -> String {
    let bytes = field.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let octal = bytes.get(i + 1..i + 4).and_then(|digits| {
            let text = std::str::from_utf8(digits).ok()?;
            u8::from_str_radix(text, 8).ok()
        });
        match (bytes[i], octal) {
            (b'\\', Some(byte)) => {
                out.push(byte);
                i += 4;
            }
            (byte, _) => {
                out.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Refuses a mountpoint that already has something mounted on it. Linux would
/// stack the new mount on top, hiding the old one, which is never what's
/// wanted.
pub(crate) fn check_mountpoint(guest_path: &str) -> Result<()> {
    // A mountpoint that doesn't exist yet has nothing on it; mounting creates it.
    let Ok(path) = fs::canonicalize(guest_path) else {
        return Ok(());
    };
    let path = path.to_string_lossy();
    if mount_points().iter().any(|point| *point == path) {
        return Err(anyhow!(
            "{path} already has something mounted on it; unmount it first"
        ));
    }
    Ok(())
}

/// Bind-mounts the folder the host shared as `tag` at `guest_path`.
///
/// The host shares a folder by linking it into the shared folder, and the 9p
/// server follows the link, so the folder is already reachable under
/// `SHARE_ROOT`, with that mount's cache mode.
fn bind_shared(tag: &str, guest_path: &str) -> Result<()> {
    bind_shared_unless(tag, guest_path, &AtomicBool::new(false))
}

/// Like `bind_shared`, but creates and mounts nothing once `abandoned` is set.
/// The restore sets it when it stops waiting for a mount.
fn bind_shared_unless(tag: &str, guest_path: &str, abandoned: &AtomicBool) -> Result<()> {
    let shared = Path::new(SHARE_ROOT).join(tag);

    // Again, in case something was mounted there while this waited for the host.
    check_mountpoint(guest_path)?;

    if !mount_points().iter().any(|point| point == SHARE_ROOT) {
        return Err(anyhow!(
            "{SHARE_ROOT} isn't mounted; log in as root once to mount it"
        ));
    }

    // The host makes the link before answering, but the guest may take a moment to see it.
    for _ in 0..APPEAR_RETRIES {
        if shared.is_dir() {
            break;
        }
        thread::sleep(APPEAR_RETRY_DELAY);
    }
    if !shared.is_dir() {
        return Err(anyhow!("{} never appeared", shared.display()));
    }

    // Checked again before each step that changes anything.
    let give_up = || {
        abandoned
            .load(Ordering::SeqCst)
            .then(|| anyhow!("given up on before it was mounted"))
    };
    if let Some(err) = give_up() {
        return Err(err);
    }
    fs::create_dir_all(guest_path).with_context(|| format!("couldn't make {guest_path}"))?;
    if let Some(err) = give_up() {
        return Err(err);
    }
    Mount::builder()
        .fstype(FilesystemType::Manual("none"))
        .flags(MountFlags::BIND)
        .mount(&shared, guest_path)
        .with_context(|| format!("couldn't mount {} at {guest_path}", shared.display()))?;
    Ok(())
}

/// The 9p cache mode the host wants the shared folder mounted with: `mmap` for
/// write-back, `readahead` for straight through. `readahead` if it doesn't say.
pub(crate) fn share_cache() -> &'static str {
    let response = run_command("share_cache".to_owned(), None, None);
    match response.ok().and_then(|message| message.value).as_deref() {
        Some("mmap") => "mmap",
        _ => FALLBACK_CACHE,
    }
}

/// Asks the host to share a folder, named by a bookmark with the name to use in
/// `arg_name`, or by a host path with an empty `arg_name`. Returns its name
/// under `/ios_host`.
fn prepare_mount(mount_arg: String, arg_name: String) -> Result<String> {
    let response = run_command(
        "prepare_mount".to_owned(),
        Some(arg_name.to_owned()),
        Some(mount_arg),
    );
    match response {
        Ok(message) => Ok(message
            .value
            .expect("did not receive a mount path in response!")),
        Err(err) => Err(err),
    }
}

/// Asks the host to share a host path. Returns its name under `/ios_host`.
pub(crate) fn prepare_mount_from_path(host_path: String) -> Result<String> {
    prepare_mount(host_path, "".to_owned())
}

/// Asks the host to share the folder for a base64 bookmark from `open_folder`,
/// as `name`. Returns its name under `/ios_host`.
pub(crate) fn prepare_mount_from_bookmark(bookmark: String, name: String) -> Result<String> {
    prepare_mount(bookmark, name)
}
