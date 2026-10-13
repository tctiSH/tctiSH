//! Commands for mounting iOS folders into the tctiSH guest.

use std::{fs, path::Path, thread, time::Duration};

use anyhow::{Context, Result, anyhow};
use sys_mount::{FilesystemType, Mount, MountFlags};

use crate::comms::run_command;

// Don't allow mounting on the host.
#[cfg(target_os = "macos")]
const MOUNT_ALLOWED: bool = false;

#[cfg(target_os = "linux")]
const MOUNT_ALLOWED: bool = true;

/// Where the app's shared folder is mounted, by `mount_shared.sh` at the first
/// root login. A folder the host shares appears there, under the name
/// `prepare_mount` answers with.
const SHARE_ROOT: &str = "/ios_host";

/// The cache mode when the host doesn't say: reads go through the page cache,
/// coherent from one open to the next, and writes go straight through. See
/// `assets/overlay/etc/profile.d/mount_shared.sh`.
const FALLBACK_CACHE: &str = "readahead";

/// How long a newly shared folder may take to appear in the guest.
const APPEAR_RETRIES: u32 = 30;
const APPEAR_RETRY_DELAY: Duration = Duration::from_millis(100);

/// Handles the "mount" command: shares the folder the user picked as `name`,
/// and mounts it at `guest_path`.
pub(crate) fn mount_from_host(
    host_bookmark: String,
    name: String,
    guest_path: String,
) -> Result<()> {
    // If we're in an environment where we can't mount, error out immediately.
    if !MOUNT_ALLOWED {
        return Err(anyhow!("mount commands must be run inside the guest!"));
    }

    check_mountpoint(&guest_path)?;
    let tag = prepare_mount_from_bookmark(host_bookmark, name)
        .context("couldn't get tctiSH ready for the mount")?;
    bind_shared(&tag, &guest_path)
}

/// Mounts a host path, rather than a bookmark: what `tctish-mount` did.
pub(crate) fn mount_from_host_path(host_path: String, guest_path: String) -> Result<()> {
    if !MOUNT_ALLOWED {
        return Err(anyhow!("mount commands must be run inside the guest!"));
    }

    check_mountpoint(&guest_path)?;
    let tag =
        prepare_mount_from_path(host_path).context("couldn't get tctiSH ready for the mount")?;
    bind_shared(&tag, &guest_path)
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
        .map(|field| {
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
        })
        .collect()
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

    fs::create_dir_all(guest_path).with_context(|| format!("couldn't make {guest_path}"))?;
    Mount::new(
        &shared,
        guest_path,
        FilesystemType::Manual("none"),
        MountFlags::BIND,
        None,
    )
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

/// Asks the host to share a folder named by a base64 bookmark, as `open_folder`
/// returns, under `name`. Returns its name under `/ios_host`.
pub(crate) fn prepare_mount_from_bookmark(bookmark: String, name: String) -> Result<String> {
    prepare_mount(bookmark, name)
}
