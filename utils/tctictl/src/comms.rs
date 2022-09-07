//! Protocol for communicating with the tctiSH host.

use std::net::TcpStream;

use anyhow::Result;
use serde::{Serialize, Deserialize};

#[cfg(target_os = "macos")]
const CONFIGURATION_HOST_ADDRESS : &str = "localhost:10050";

#[cfg(target_os = "linux")]
const CONFIGURATION_HOST_ADDRESS : &str = "192.168.100.2:10050";

/// Message exchanged back and forth with our 
#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct ConfigurationMessage {

    /// The command being executed / responded to.
    command: String,

    /// Any key data associated with this command.
    key: Option<String>,

    /// The argument to the message.
    value: Option<String>

}

/// Sends a command message to the host, and receives a response.
pub(crate) fn exchange_message(message: ConfigurationMessage) -> Result<ConfigurationMessage> {

    // Get a connection to our ConfigServer...
    let socket = TcpStream::connect(CONFIGURATION_HOST_ADDRESS).unwrap();

    // ... cajole our message into being JSON, and splat it up to the host.
    serde_json::to_writer(&socket, &message).unwrap();

    // Finally, fetch a response, if we have one.
    let response : ConfigurationMessage = serde_json::from_reader(&socket)?;
    return Ok(response);
}


/// Sends a command message to the host, and receives a response.
pub(crate) fn run_command(command: String, key: Option<String>, value: Option<String>) -> Result<ConfigurationMessage> {
    let message = ConfigurationMessage{ command, key, value };
    return exchange_message(message)
}

