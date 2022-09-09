/**
 * tctiSH configuration and control tool.
 */

mod comms;

// Simple commands.
mod simple;

// File sharing commands.
mod mount;

use clap::{Parser, Subcommand};


//
// CLI configuration
//

#[derive(Debug, Parser)]
#[clap(name = "tctish")]
#[clap(about = "configuration and control tool for tctiSH", long_about = None)]
struct Cli {

    #[clap(subcommand)]
    subcommand: Commands,
}


#[derive(Debug, Subcommand)]
enum Commands {

    // Simple font configuration.
    #[clap(arg_required_else_help = false)]
    #[clap(about ="Configure the terminal's font")]
    Font {

        #[clap(help ="The property to set")]
        #[clap(possible_value = "name")]
        #[clap(possible_value = "size")]
        property: Option<String>,

        #[clap(help ="The value to set the font-property to")]
        value: Option<String>
    },

    // Low-level commands not used by typical users.
    #[clap(about ="Commands that directly poke the configuration server's internals")]
    Lowlevel {
        #[clap(subcommand)]
        subcommand: LowlevelCommands,
    }
}


#[derive(Debug, Subcommand)]
enum LowlevelCommands {

    // Simple font configuration.
    #[clap(arg_required_else_help = false)]
    #[clap(about ="Issues a raw API command")]
    Raw {

        #[clap(help ="The command verb to be issued")]
        command: String,

        #[clap(help ="An optional key associated with the given command")]
        key: Option<String>,

        #[clap(help ="An optional value associated with the given command")]
        value: Option<String>
    },

    // Simple font configuration.
    #[clap(arg_required_else_help = false)]
    #[clap(about ="Configure the terminal's font")]
    PrepareMount {
        host_path: String
    },
}

//
// CLI command dispatch.
//

fn main() {
    let args = Cli::parse();

    // Delegate control to our subcommand handlers.
    match args.subcommand {

        // Font configuration and control.
        Commands::Font { property, value } => {
            simple::handle_font(property, value);
        }

        Commands::Lowlevel { subcommand } => {
            lowlevel(subcommand)
        }
    }
}


// Provides access to our low-level commands.
// Mostly peeks into the backends of our higher-level commands.
fn lowlevel(subcommand: LowlevelCommands) {

    match subcommand {

        LowlevelCommands::Raw { command, key, value } => {
            let result = comms::run_command(command, key, value);
            dbg!(result);
        }


        LowlevelCommands::PrepareMount { host_path } => {
            let result = mount::prepare_mount(host_path);
            dbg!(result);
        }

    }

}
