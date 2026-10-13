//! Protocol for communicating with the tctiSH host.
//!
//! Over the virtio-serial port `io.ara.tctish.control`, one JSON message per
//! line each way.
//!
//! The port isn't a connection. Linux lets one process have it open at a time,
//! and anything the host sends while nobody has it open goes to the next
//! process to open it. So each request carries an id, and any answer with
//! another id, such as one meant for a tctictl stopped with Ctrl-C, is ignored.
//!
//! An answer may also never come: the guest is restored from a snapshot taken
//! while this was waiting, or the app is relaunched into one. So while it
//! waits, tctictl asks every few seconds whether the app is still handling the
//! request, and gives up with `Lost` once the app has no record of it.

use std::{
    fmt,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, ErrorKind, Write},
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::PathBuf,
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};

/// The name QEMU gives tctictl's port.
const PORT_NAME: &str = "io.ara.tctish.control";

/// Held while a request is out, so that a second tctictl waits for the first
/// rather than failing to open the port. In /run, which only root can write, so
/// that nobody else can create and hold it.
const LOCK_PATH: &str = "/run/tctictl.lock";

/// How long to keep trying a port something else has open.
const BUSY_RETRIES: u32 = 50;
const BUSY_RETRY_DELAY: Duration = Duration::from_millis(100);

/// How long to wait for an answer before asking whether one is coming.
const STILL_WAITING_INTERVAL_MS: libc::c_int = 2000;

/// The request's answer is lost: the app has no record of the request, so the
/// guest was restored to a moment when it was waiting, or the app restarted.
#[derive(Debug)]
pub(crate) struct Lost;

impl fmt::Display for Lost {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "tctiSH restarted before answering; try again")
    }
}

impl std::error::Error for Lost {}

/// Message exchanged back and forth with our
#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct ConfigurationMessage {
    /// Which request this is, or answers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,

    /// The command being executed / responded to.
    pub command: String,

    /// Any key data associated with this command.
    pub key: Option<String>,

    /// The argument to the message.
    pub value: Option<String>,

    /// The controlling tty of the tctictl that sent the request, as
    /// `controlling_tty` gives it, so that the app can tell which of its TTYs
    /// the request came from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tty: Option<String>,
}

/// This process's controlling tty, by its name in Linux, or as `MAJOR:MINOR` if
/// it has no name to find (a pseudo-terminal, as under tmux), or None if it has
/// none.
fn controlling_tty() -> Option<String> {
    // The seventh field, tty_nr, is the fifth after the command's name, which is in parentheses and
    // can itself hold spaces and parentheses.
    let stat = fs::read_to_string("/proc/self/stat").ok()?;
    let fields = &stat[stat.rfind(')')? + 1..];
    let tty: u32 = fields.split_whitespace().nth(4)?.parse().ok()?;
    if tty == 0 {
        return None;
    }

    // Linux packs the device number as it does for an old-style dev_t.
    let major = (tty >> 8) & 0xfff;
    let minor = (tty & 0xff) | ((tty >> 12) & 0xfff00);
    let named = fs::read_link(format!("/sys/dev/char/{major}:{minor}"))
        .ok()
        .and_then(|device| Some(device.file_name()?.to_str()?.to_owned()));
    Some(named.unwrap_or_else(|| format!("{major}:{minor}")))
}

/// Finds the port by its name. There is no udev, so `/dev/virtio-ports/<name>`
/// never appears; devtmpfs makes only the kernel's `/dev/vportNpM`, numbered in
/// the order the ports were added.
fn find_port() -> Result<PathBuf> {
    let ports = fs::read_dir("/sys/class/virtio-ports")
        .context("no virtio-serial ports; is this tctiSH?")?;

    for port in ports.flatten() {
        let name = fs::read_to_string(port.path().join("name")).unwrap_or_default();
        if name.trim_end() == PORT_NAME {
            return Ok(PathBuf::from("/dev").join(port.file_name()));
        }
    }

    Err(anyhow!("no port named {PORT_NAME}; is this tctiSH?"))
}

/// Takes the lock that keeps tctictls from opening the port at the same time,
/// waiting for it. Held until the file is dropped.
fn lock() -> Result<File> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(LOCK_PATH)
        .map_err(|err| match err.kind() {
            ErrorKind::PermissionDenied => anyhow!("tctictl talks to tctiSH as root"),
            _ => anyhow::Error::new(err).context(format!("couldn't open {LOCK_PATH}")),
        })?;

    // SAFETY: a valid descriptor, which `file` keeps open for the call.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(std::io::Error::last_os_error()).context("couldn't take tctictl's lock");
    }
    Ok(file)
}

/// Opens the port, waiting a while if something else has it open.
fn open_port() -> Result<File> {
    let path = find_port()?;

    for _ in 0..BUSY_RETRIES {
        match OpenOptions::new().read(true).write(true).open(&path) {
            Ok(port) => return Ok(port),
            Err(err) if err.raw_os_error() == Some(libc::EBUSY) => thread::sleep(BUSY_RETRY_DELAY),
            Err(err) if err.kind() == ErrorKind::PermissionDenied => {
                return Err(anyhow!("tctictl talks to tctiSH as root"));
            }
            Err(err) => return Err(err).with_context(|| format!("couldn't open {path:?}")),
        }
    }

    Err(anyhow!("{path:?} is busy; is something else reading it?"))
}

/// An id that no other request is likely to have had: this process, and now.
fn new_id() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}-{}", std::process::id(), now.as_nanos())
}

/// Sends a line to the host, starting with a newline, so that a write cut off
/// part way by a stopped tctictl stays on a line by itself.
fn send_line(port: &mut File, message: &ConfigurationMessage) -> Result<()> {
    let raw_message = "\n".to_owned() + &serde_json::to_string(message)? + "\n";
    port.write_all(raw_message.as_bytes())
        .context("couldn't send to tctiSH")
}

/// Waits up to `STILL_WAITING_INTERVAL_MS` for the port to have something to
/// read, and says whether it has.
fn readable(port: &File) -> Result<bool> {
    let mut descriptor = libc::pollfd {
        fd: port.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one valid pollfd, for the length of the call.
    match unsafe { libc::poll(&mut descriptor, 1, STILL_WAITING_INTERVAL_MS) } {
        -1 if std::io::Error::last_os_error().kind() == ErrorKind::Interrupted => Ok(false),
        -1 => Err(std::io::Error::last_os_error()).context("couldn't wait for tctiSH"),
        ready => Ok(ready > 0),
    }
}

/// Sends a command message to the host, and receives a response.
pub(crate) fn exchange_message(mut message: ConfigurationMessage) -> Result<ConfigurationMessage> {
    let _lock = lock()?;
    let mut port = open_port()?;
    let mut reader = BufReader::new(port.try_clone()?);

    let id = new_id();
    message.id = Some(id.clone());
    message.tty = controlling_tty();
    send_line(&mut port, &message)?;

    let still_waiting = ConfigurationMessage {
        id: Some(id.clone()),
        command: "still_waiting".to_owned(),
        key: None,
        value: None,
        tty: None,
    };

    // Every request gets an answer with its id; lines with another id are someone else's.
    let response = loop {
        if reader.buffer().is_empty() && !readable(&port)? {
            send_line(&mut port, &still_waiting)?;
            continue;
        }

        let mut line = String::new();
        if reader
            .read_line(&mut line)
            .context("couldn't read from tctiSH")?
            == 0
        {
            return Err(anyhow!("tctiSH went away without answering"));
        }

        let Ok(response) = serde_json::from_str::<ConfigurationMessage>(&line) else {
            continue;
        };
        if response.id.as_deref() != Some(id.as_str()) {
            continue;
        }
        if response.command == "still_waiting.response" {
            if response.value.as_deref() == Some("unknown") {
                return Err(anyhow::Error::new(Lost));
            }
            continue;
        }
        break response;
    };

    // If we received an error response from the host, translate it into an error.
    if response.key.as_deref() == Some("error") {
        return Err(anyhow!(response.value.unwrap_or_default()));
    }

    Ok(response)
}

/// Sends a command message to the host, and receives a response.
pub(crate) fn run_command(
    command: String,
    key: Option<String>,
    value: Option<String>,
) -> Result<ConfigurationMessage> {
    let message = ConfigurationMessage {
        id: None,
        command,
        key,
        value,
        tty: None,
    };
    exchange_message(message)
}
