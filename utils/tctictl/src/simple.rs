
use anyhow::Result;

use crate::comms::run_command;


/// The command used to set font parameters.
const COMMAND_FONT: &str = "font";


/// Returns a given tctiSH font property.
fn get_font_property(property: &str) -> Result<String> {
    return Ok("<TODO>".to_owned())
}


/// Sets a font property, changing the way the host displays its terminal.
fn set_font_property(property: String, value: String) -> Result<()> {
    run_command(COMMAND_FONT.to_owned(), Some(property), Some(value)).map(|_| ())
}

/// Handles font configuration commands.
pub(crate) fn handle_font(property: Option<String>, value: Option<String>) {

    // If we have a property, get or set it.
    if let Some(property) = property {

        // If we have a value, use it.
        if let Some(value) = value {
            let _ = set_font_property(property, value);
        } 

        // Otherwise, fetch it.
        else {
            println!("{} = {}\n", &property, get_font_property(&property).unwrap());
        }
    } 
    // If we don't have any arguments, print our known values and 
    else {
        println!();
        println!("Font parameters:"); 
        println!("    name = {}", get_font_property("name").unwrap());
        println!("    size = {}", get_font_property("size").unwrap());
        println!();
    }

}
