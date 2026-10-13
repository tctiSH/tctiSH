//! The machine itself, as far as the host allows from inside: its snapshots,
//! and QEMU's monitor.

use std::io::{self, BufRead, Write};

use anyhow::Result;

use crate::comms::{Lost, run_command};

/// What the host printed, if it printed anything.
fn print_output(output: Option<String>) {
    if let Some(output) = output.filter(|output| !output.is_empty()) {
        println!("{output}");
    }
}

/// Saves a snapshot of the whole machine, Linux and its disk, as `name`.
pub(crate) fn save(name: String) -> Result<()> {
    // Write out dirty data first. Otherwise unwritten shared-folder data goes into the snapshot,
    // and loading it later writes that old data over whatever the host has written since.
    // SAFETY: no arguments, and nothing to go wrong.
    unsafe { libc::sync() };

    match run_command("snapshot_save".to_owned(), None, Some(name.clone())) {
        Ok(response) => print_output(response.value),

        // The app has no record of the request, so Linux was restored to a moment when this was
        // waiting, which can only be inside this snapshot: nothing else is saved meanwhile.
        Err(err) if err.downcast_ref::<Lost>().is_some() => {
            println!("Restored from snapshot '{name}'.");
        }
        Err(err) => return Err(err),
    }
    Ok(())
}

/// Loads the snapshot `name`. Returns only on failure: once the load works,
/// Linux is as it was when the snapshot was taken, and this tctictl never ran.
pub(crate) fn load(name: String) -> Result<()> {
    println!("Loading '{name}'...");
    io::stdout().flush()?;

    let response = run_command("snapshot_load".to_owned(), None, Some(name))?;
    print_output(response.value);
    Ok(())
}

pub(crate) fn delete(name: String) -> Result<()> {
    let response = run_command("snapshot_delete".to_owned(), None, Some(name))?;
    print_output(response.value);
    Ok(())
}

pub(crate) fn list() -> Result<()> {
    let response = run_command("snapshot_list".to_owned(), None, None)?;
    print_output(response.value);
    Ok(())
}

/// The arguments as one monitor command, quoted where needed, so that an
/// argument with a space in it stays one argument.
fn join_arguments(arguments: &[String]) -> String {
    arguments
        .iter()
        .map(|argument| {
            if !argument.is_empty() && !argument.contains([' ', '"', '\\']) {
                return argument.clone();
            }
            let escaped = argument.replace('\\', "\\\\").replace('"', "\\\"");
            format!("\"{escaped}\"")
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// Runs one monitor command and prints what it printed.
fn monitor_command(command: String) -> Result<()> {
    let response = run_command("monitor".to_owned(), None, Some(command))?;
    print_output(response.value);
    Ok(())
}

/// Runs `command` on QEMU's monitor, or with none, reads commands one to a line
/// until the end of input.
pub(crate) fn monitor(command: Vec<String>) -> Result<()> {
    if !command.is_empty() {
        return monitor_command(join_arguments(&command));
    }

    let stdin = io::stdin();
    loop {
        print!("(qemu) ");
        io::stdout().flush()?;

        let mut line = String::new();
        if stdin.lock().read_line(&mut line)? == 0 {
            println!();
            return Ok(());
        }

        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if let Err(err) = monitor_command(line.to_owned()) {
            eprintln!("{err:#}");
        }
    }
}
