//! Protocol for communicating with the tctiSH host.

use std::{net::TcpStream, io::BufRead, time::Duration, io::{BufReader, Write}};

use anyhow::{Result, anyhow};
use serde::{Serialize, Deserialize};

#[cfg(target_os = "macos")]
const CONFIGURATION_HOST_ADDRESS : &str = "localhost:10050";

#[cfg(target_os = "linux")]
const CONFIGURATION_HOST_ADDRESS : &str = "192.168.100.2:10050";

/// Message exchanged back and forth with our 
#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct ConfigurationMessage {

    /// The command being executed / responded to.
    pub command: String,

    /// Any key data associated with this command.
    pub key: Option<String>,

    /// The argument to the message.
    pub value: Option<String>

}

/// Sends a command message to the host, and receives a response.
pub(crate) fn exchange_message(message: ConfigurationMessage) -> Result<ConfigurationMessage> {

    // Get a connection to our ConfigServer...
    let mut socket = TcpStream::connect(CONFIGURATION_HOST_ADDRESS)?;
    let mut socket_reader = BufReader::new(socket.try_clone()?);

    // ... cajole our message into being JSON, and splat it up to the host.
    let raw_message = serde_json::to_string(&message)? + "\n";
    let size_written = socket.write(&raw_message.into_bytes());
    if size_written.is_err() || (size_written.unwrap() == 0){
        return Err(anyhow!("response error'd out without data"));
    }

    // Every packet from the ConfigServer should have a response; try to read it.
    let mut raw_response = String::new();
    let size_read = socket_reader.read_line(&mut raw_response);
    if size_read.is_err() || (size_read.unwrap() == 0){
        return Err(anyhow!("response error'd out without data"));
    }

    // Finally, fetch a response, if we have one.
    let response : ConfigurationMessage = serde_json::from_str(&raw_response)?;

    // If we received an error response from the host, translate it into an error.
    if let Some(key) = &response.key {
        if key == "error" {
            return Err(anyhow!("error response: ".to_owned() + &response.value.unwrap()));
        }
    }

    Ok(response)
}


/// Sends a command message to the host, and receives a response.
pub(crate) fn run_command(command: String, key: Option<String>, value: Option<String>) -> Result<ConfigurationMessage> {
    let message = ConfigurationMessage{ command, key, value };
    exchange_message(message)
}

