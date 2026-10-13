//! Setting the guest's clock to the host's, for `tctish-agent`.

use std::io;

use anyhow::{Context, Result, anyhow};

/// How far behind the clock may be before it is set, in nanoseconds.
///
/// The host stamps its time as it sends it, and the time arrives after the
/// agent has started this, which takes tens of milliseconds under TCTI. So it
/// is always a little behind, and setting the clock to it every time would only
/// move the clock back by that much. A cold boot reads the RTC, which has
/// one-second resolution, and a resume once came back three days behind; both
/// are well clear of this.
const BEHIND_THRESHOLD_NS: i128 = 250_000_000;

/// How far ahead the clock may be, in nanoseconds. More slack than behind: the
/// agent answers one request at a time, so a time sent while a `sync` is still
/// running arrives late by however long that takes, and the clock looks ahead
/// by as much. Moving the clock back by mistake is also worse, giving files
/// written meanwhile times in the future.
const AHEAD_THRESHOLD_NS: i128 = 2_000_000_000;

const NS_PER_SECOND: i128 = 1_000_000_000;

/// Sets the clock to `host_time`, `<seconds>.<fraction>` since the epoch, if it
/// is far enough out. Returns what it did and the offset it found, in seconds,
/// positive when the guest was behind: "stepped 1.234567" or "kept -0.031000".
pub(crate) fn set_clock(host_time: &str) -> Result<String> {
    let host = parse_time(host_time)?;
    let offset = host - now()?;

    if (-AHEAD_THRESHOLD_NS..=BEHIND_THRESHOLD_NS).contains(&offset) {
        return Ok(format!("kept {}", seconds(offset)));
    }

    let time = libc::timespec {
        tv_sec: host.div_euclid(NS_PER_SECOND) as _,
        tv_nsec: host.rem_euclid(NS_PER_SECOND) as _,
    };
    // SAFETY: `time` is a valid timespec that outlives the call.
    if unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &time) } != 0 {
        return Err(io::Error::last_os_error()).context("couldn't set the clock");
    }

    Ok(format!("stepped {}", seconds(offset)))
}

/// The time now, in nanoseconds since the epoch.
fn now() -> Result<i128> {
    let mut time = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `time` is a valid timespec for the call to write into.
    if unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut time) } != 0 {
        return Err(io::Error::last_os_error()).context("couldn't read the clock");
    }

    Ok(time.tv_sec as i128 * NS_PER_SECOND + time.tv_nsec as i128)
}

/// Parses `<seconds>[.<fraction>]` into nanoseconds, keeping nine digits of the
/// fraction at most.
fn parse_time(text: &str) -> Result<i128> {
    let bad = || anyhow!("not a time: {text}");

    let (whole, fraction) = text.split_once('.').unwrap_or((text, ""));
    let digits = |part: &str| part.bytes().all(|byte| byte.is_ascii_digit());
    if whole.is_empty() || !digits(whole) || !digits(fraction) {
        return Err(bad());
    }

    let seconds: i128 = whole.parse().map_err(|_| bad())?;
    let fraction: String = fraction
        .chars()
        .chain("000000000".chars())
        .take(9)
        .collect();
    let nanoseconds: i128 = fraction.parse().map_err(|_| bad())?;

    Ok(seconds * NS_PER_SECOND + nanoseconds)
}

/// Nanoseconds as seconds, to the microsecond.
fn seconds(nanoseconds: i128) -> String {
    let sign = if nanoseconds < 0 { "-" } else { "" };
    let micros = nanoseconds.abs() / 1000;
    format!("{sign}{}.{:06}", micros / 1_000_000, micros % 1_000_000)
}
