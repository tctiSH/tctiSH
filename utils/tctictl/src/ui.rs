//! Tools for popping up host UIs via the tctiSH ConfigServer.

use anyhow::{Result, anyhow};

use crate::comms::run_command;

/// Selects a folder from the host, and ensures tctiSH can access it.
/// Returns the unix file path for the relevant folder.
pub(crate) fn select_folder_as_path() -> Result<String> {

    // Pop up our UI, and fetch the actual folder.
    let response = run_command("choose_folder".to_owned(), None, None);
    match response {
        Ok(message) => {
            let result_type = message.key.expect("response didn't indicate a response type!");

            // If we got back a status (e.g. 'cancelled'), convert that to an error type.
            if result_type == "status" {
                return Err(anyhow!(message.value.unwrap_or("-none-".to_owned())));
            }

            return Ok(message.value.expect("ConfigServer indicated we have a folder, but didn't provide one!"));
        }
        Err(err) => {
            return Err(err);
        }
    }
}


/// Selects a folder from the host, and ensures tctiSH can access it.
/// Returns a base64 'bookmark' that can be used with e.g. the mount API calls.
pub(crate) fn select_folder_as_bookmark() -> Result<String> {

    // Pop up our UI, and fetch the actual folder.
    let response = run_command("open_folder".to_owned(), None, None);
    match response {
        Ok(message) => {
            let result_type = message.key.expect("response didn't indicate a response type!");

            // If we got back a status (e.g. 'cancelled'), convert that to an error type.
            if result_type == "status" {
                return Err(anyhow!(message.value.unwrap_or("-none-".to_owned())));
            }

            return Ok(message.value.expect("ConfigServer indicated we have a folder, but didn't provide one!"));
        }
        Err(err) => {
            return Err(err);
        }
    }
}

