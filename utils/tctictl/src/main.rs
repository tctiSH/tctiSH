/**
 * tctiSH configuration and control tool.
 */

mod comms;
mod mount;
mod simple;
mod ui;

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

    #[clap(about ="Mount an iOS path into tctiSH")]
    Mount {
        #[clap(help ="The linux path where the directory should be mounted")]
        mountpoint: String
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

    #[clap(about ="Prepares a host directory to be mounted into tctiSH")]
    PrepareMount {
        ios_path: String
    },

    #[clap(about ="Directly map a host path into tctiSH")]
    Mount {
        ios_path: String,
        linux_path: String
    },


    #[clap(about ="Fetches the host's perspective on our CWD.")]
    GetCWD {},
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

        // Mount a host folder into the guest.
        Commands::Mount { mountpoint } => {
            let folder = ui::select_folder_as_bookmark();
            match folder {

                // If we got a path in response, mount it.
                Ok(bookmark) => {
                    let result = mount::mount_from_host(bookmark, mountpoint);
                    if let Err(result) = result {
                        eprintln!("Failed to mount: {}\n", result);
                    }
                }

                // Otherwise, error out.
                Err(err) => {
                    eprintln!("Couldn't select a folder to mount: {}", err);
                }
            }

        }

        // General low-level subcommands.
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

        LowlevelCommands::PrepareMount { ios_path } => {
            let result = mount::prepare_mount_from_path(ios_path);
            dbg!(result);
        }

        LowlevelCommands::Mount { ios_path, linux_path } => {
            let result = mount::mount_from_host(ios_path, linux_path);
            if let Err(result) = result {
                eprintln!("Failed to mount: {}\n", result);
            }
        }

        LowlevelCommands::GetCWD {} => {
            let result = simple::handle_getcwd();
            match result {

                // If we got a path in response, mount it.
                Ok(cwd) => {
                    println!("{}", cwd);
                }

                // Otherwise, error out.
                Err(err) => {
                    eprintln!("Couldn't get the CWD: {}", err);
                }
            }
        }


    }

}
