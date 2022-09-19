///! Commands for mounting iOS folders into the tctiSH guest.
use std::{fs, thread, time::Duration};

use anyhow::{Result, anyhow};
use sys_mount::{FilesystemType, Mount, MountFlags};

use crate::comms::run_command;

// Don't allow mounting on the host.
#[cfg(target_os = "macos")]
const MOUNT_ALLOWED : bool = false;

#[cfg(target_os = "linux")]
const MOUNT_ALLOWED : bool = true;

/// Options used when mounting host filesystems.
const HOST_MOUNT_OPTIONS : &str = "trans=virtio,version=9p2000.L,debug=0x40";

/// The delay between a successful prepare_mount() and returning.
/// Gives QEMU time to actually make things available.
const PREPARE_MOUNT_DELAY : Duration =  Duration::new(1, 0);

/// Handles the "mount" command.
pub(crate) fn mount_from_host(host_bookmark: String, guest_path: String) -> Result<()> {

    // If we're in an environment where we can't mount, error out immediately.
    if !MOUNT_ALLOWED {
        return Err(anyhow!("mount commands must be run inside the guest!"));
    }

    // Set up mounting from inside the guest...
    let mount_tag = prepare_mount_from_bookmark(host_bookmark, guest_path).expect("failed to prepare mount from host!");
    scan_for_new_virtfs_channels().expect("could not set up guest to receive mount!");

    // ... and perform the mount itself.
    /*
    FIXME: do this
    let result = Mount::new(
        mount_tag,
        guest_path,
        FilesystemType::Manual("9p"),
        MountFlags::empty(),
        Some(HOST_MOUNT_OPTIONS)
    );
    if let Err(result) = result {
        return Err(anyhow!(format!("failed to mount device: {}", result)));
    }
    */

    Ok(())
}


/// Performs a full mount from a host path identifier, which can be a bookmark or a path.
/// Argtype should indicate if this is a 'path' or a 'bookmark' using those strings.
/// Returns a tag that can be used to mount the given folder using 9pfs.
fn prepare_mount(mount_arg: String, argName: String) -> Result<String> {
    let response = run_command("prepare_mount".to_owned(), Some(argName.to_owned()), Some(mount_arg));
    match response {
        Ok(message) => {
            thread::sleep(PREPARE_MOUNT_DELAY);
            return Ok(message.value.expect("did not receive a mount path in response!"));
        }
        Err(err) => {
            return Err(err);
        }
    }
}


/// Prepares QEMU to mount a host folder into our guest.
/// Returns a tag that can be used to mount the given folder using 9pfs.
pub(crate) fn prepare_mount_from_path(host_path: String) -> Result<String> {
    prepare_mount(host_path, "".to_owned())
}

/// Prepares QEMU to mount a folder from a base64 'bookmark' e.g. returned from other API calls.
/// Returns a tag that can be used to mount the given folder using 9pfs.
pub(crate) fn prepare_mount_from_bookmark(bookmark: String, name: String) -> Result<String> {
    prepare_mount(bookmark, name) 
}


/// Requests that the guest check for new PCI(e) channels with which it can
/// establish 9pfs connections, for mounting host filesystems.
fn scan_for_new_virtfs_channels() -> Result<()> {
    let result = fs::write("/sys/bus/pci/rescan", "1");
    if let Err(result) = result {
        return Err(anyhow!(format!("could not rescan PCI(e) devices: {}", result)));
    }

    Ok(())
}

