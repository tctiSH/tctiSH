///! Commands for mounting iOS folders into the tctiSH guest.
use anyhow::Result;

use crate::comms::run_command;

pub(crate) fn prepare_mount(host_path: String) -> Result<String> {
    let response = run_command("prepare_mount".to_owned(), None, Some(host_path));
    response.map ( |message| message.value.unwrap() )
}
