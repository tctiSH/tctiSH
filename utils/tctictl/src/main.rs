//! tctiSH configuration and control tool.

mod clock;
mod comms;
mod machine;
mod mount;
mod simple;
mod ui;

use clap::{Parser, Subcommand};

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
    #[clap(about = "Configure the terminal's font")]
    Font {
        #[clap(help = "The property to set")]
        #[clap(possible_value = "name")]
        #[clap(possible_value = "size")]
        property: Option<String>,

        #[clap(help = "The value to set the font-property to")]
        value: Option<String>,
    },

    #[clap(about = "Mount an iOS folder, picked on the device, into tctiSH")]
    Mount {
        #[clap(help = "The linux path where the folder should be mounted")]
        mountpoint: String,

        #[clap(
            long,
            help = "What to call it under /ios_host; the mountpoint's name if not given"
        )]
        name: Option<String>,
    },

    #[clap(about = "Save, load and list snapshots of the whole machine")]
    Snapshot {
        #[clap(subcommand)]
        subcommand: SnapshotCommands,
    },

    #[clap(about = "Run commands on QEMU's monitor, or with none, read them from the input")]
    Monitor {
        #[clap(help = "The command, and its arguments")]
        #[clap(allow_hyphen_values = true)]
        command: Vec<String>,
    },

    // Low-level commands not used by typical users.
    #[clap(about = "Commands that directly poke the configuration server's internals")]
    Lowlevel {
        #[clap(subcommand)]
        subcommand: LowlevelCommands,
    },
}

#[derive(Debug, Subcommand)]
enum SnapshotCommands {
    #[clap(
        about = "Save a snapshot of Linux and its disk. Each keeps Linux's memory, so delete old ones"
    )]
    Save { name: String },

    #[clap(about = "Go back to a snapshot. Everything since is lost")]
    Load { name: String },

    #[clap(about = "Delete a snapshot")]
    Delete { name: String },

    #[clap(about = "List the snapshots on this disk")]
    List {},
}

#[derive(Debug, Subcommand)]
enum LowlevelCommands {
    #[clap(arg_required_else_help = false)]
    #[clap(about = "Issues a raw API command")]
    Raw {
        #[clap(help = "The command verb to be issued")]
        command: String,

        #[clap(help = "An optional key associated with the given command")]
        key: Option<String>,

        #[clap(help = "An optional value associated with the given command")]
        value: Option<String>,
    },

    #[clap(about = "Prepares a host directory to be mounted into tctiSH")]
    PrepareMount { ios_path: String },

    #[clap(about = "Directly map a host path into tctiSH")]
    Mount { ios_path: String, linux_path: String },

    #[clap(about = "Prints the 9p cache mode tctiSH wants shared folders mounted with")]
    ShareCache {},

    #[clap(about = "Prints the command tctiSH starts in new terminals, or nothing for the shell")]
    DefaultCommand {},

    #[clap(about = "Fetches the host's perspective on our CWD.")]
    GetCWD {},

    #[clap(about = "Sets the clock to the host's, if it is far enough out (for tctish-agent)")]
    SetClock {
        #[clap(help = "The host's time, as <seconds>.<fraction> since the epoch")]
        time: String,
    },
}

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
        Commands::Mount { mountpoint, name } => {
            let name = name.unwrap_or_else(|| mount::default_name(&mountpoint));

            // Before the picker, so that a name the app won't take doesn't cost a trip through it.
            if !mount::is_share_name(&name) {
                eprintln!(
                    "'{name}' isn't a name for a shared folder: up to 64 letters, digits, '.', \
                     '_' and '-'"
                );
                std::process::exit(1);
            }

            if let Err(err) = mount::check_mountpoint(&mountpoint) {
                eprintln!("Failed to mount: {err:#}");
                std::process::exit(1);
            }

            let folder = ui::select_folder_as_bookmark();
            match folder {
                // If we got a path in response, mount it.
                Ok(bookmark) => {
                    let result = mount::mount_from_host(bookmark, name, mountpoint);
                    if let Err(result) = result {
                        eprintln!("Failed to mount: {:#}", result);
                        std::process::exit(1);
                    }
                }

                // Otherwise, error out.
                Err(err) => {
                    eprintln!("Couldn't select a folder to mount: {}", err);
                }
            }
        }

        Commands::Snapshot { subcommand } => {
            let result = match subcommand {
                SnapshotCommands::Save { name } => machine::save(name),
                SnapshotCommands::Load { name } => machine::load(name),
                SnapshotCommands::Delete { name } => machine::delete(name),
                SnapshotCommands::List {} => machine::list(),
            };
            exit_on_error(result);
        }

        Commands::Monitor { command } => exit_on_error(machine::monitor(command)),

        // General low-level subcommands.
        Commands::Lowlevel { subcommand } => lowlevel(subcommand),
    }
}

/// Says what went wrong, and exits with a failure, if anything did.
fn exit_on_error(result: anyhow::Result<()>) {
    if let Err(err) = result {
        eprintln!("{err:#}");
        std::process::exit(1);
    }
}

// Provides access to our low-level commands. Mostly peeks into the backends of our higher-level
// commands.
fn lowlevel(subcommand: LowlevelCommands) {
    match subcommand {
        LowlevelCommands::Raw {
            command,
            key,
            value,
        } => {
            // Printing it is the whole job of a raw command, and `dbg!` prints an `Err` as readily
            // as an `Ok`, so there is nothing left to do with what it hands back.
            let result = comms::run_command(command, key, value);
            let _ = dbg!(result);
        }

        LowlevelCommands::PrepareMount { ios_path } => {
            let result = mount::prepare_mount_from_path(ios_path);
            let _ = dbg!(result);
        }

        LowlevelCommands::Mount {
            ios_path,
            linux_path,
        } => {
            let result = mount::mount_from_host_path(ios_path, linux_path);
            if let Err(result) = result {
                eprintln!("Failed to mount: {:#}", result);
                std::process::exit(1);
            }
        }

        LowlevelCommands::ShareCache {} => println!("{}", mount::share_cache()),

        LowlevelCommands::DefaultCommand {} => {
            exit_on_error(simple::default_command().map(|command| println!("{command}")))
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

        // One line, which tctish-agent passes on to the host as its answer.
        LowlevelCommands::SetClock { time } => match clock::set_clock(&time) {
            Ok(done) => println!("{done}"),
            Err(err) => {
                eprintln!("{err:#}");
                std::process::exit(1);
            }
        },
    }
}
