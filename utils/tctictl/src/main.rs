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
#[command(name = "tctish")]
#[command(about = "configuration and control tool for tctiSH", long_about = None)]
struct Cli {
    #[command(subcommand)]
    subcommand: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    // Simple font configuration.
    #[command(arg_required_else_help = false)]
    #[command(about = "Configure the terminal's font")]
    Font {
        #[arg(help = "The property to set")]
        #[arg(value_parser = ["name", "size"])]
        property: Option<String>,

        #[arg(help = "The value to set the font-property to")]
        value: Option<String>,
    },

    #[command(
        about = "Mount an iOS folder into tctiSH, picked on the device; --name with a folder \
                    picked before mounts it again"
    )]
    Mount {
        #[arg(help = "The linux path where the folder should be mounted")]
        mountpoint: String,

        #[arg(
            long,
            help = "What to call it under /ios_host; the mountpoint's name if not given"
        )]
        name: Option<String>,
    },

    #[command(about = "List the iOS folders this disk mounts again at boot")]
    Mounts {},

    #[command(
        about = "Forget an iOS folder from `mount -t ios`: unmount it, and don't mount it again"
    )]
    Forget {
        #[arg(help = "Its name under /ios_host")]
        name: String,
    },

    #[command(about = "Save, load and list snapshots of the whole machine")]
    Snapshot {
        #[command(subcommand)]
        subcommand: SnapshotCommands,
    },

    #[command(about = "Run commands on QEMU's monitor, or with none, read them from the input")]
    Monitor {
        #[arg(help = "The command, and its arguments")]
        #[arg(allow_hyphen_values = true)]
        command: Vec<String>,
    },

    // Low-level commands not used by typical users.
    #[command(about = "Commands that directly poke the configuration server's internals")]
    Lowlevel {
        #[command(subcommand)]
        subcommand: LowlevelCommands,
    },
}

#[derive(Debug, Subcommand)]
enum SnapshotCommands {
    #[command(
        about = "Save a snapshot of Linux and its disk. Each keeps Linux's memory, so delete old ones"
    )]
    Save { name: String },

    #[command(about = "Go back to a snapshot. Everything since is lost")]
    Load { name: String },

    #[command(about = "Delete a snapshot")]
    Delete { name: String },

    #[command(about = "List the snapshots on this disk")]
    List {},
}

#[derive(Debug, Subcommand)]
enum LowlevelCommands {
    #[command(arg_required_else_help = false)]
    #[command(about = "Issues a raw API command")]
    Raw {
        #[arg(help = "The command verb to be issued")]
        command: String,

        #[arg(help = "An optional key associated with the given command")]
        key: Option<String>,

        #[arg(help = "An optional value associated with the given command")]
        value: Option<String>,
    },

    #[command(about = "Prepares a host directory to be mounted into tctiSH")]
    PrepareMount { ios_path: String },

    #[command(about = "Directly map a host path into tctiSH")]
    Mount { ios_path: String, linux_path: String },

    #[command(about = "Prints the 9p cache mode tctiSH wants shared folders mounted with")]
    ShareCache {},

    #[command(about = "Mount the remembered iOS folders again, without the picker")]
    RestoreMounts {
        #[arg(
            long,
            help = "File descriptor of the restore lock to release when done (for mount_shared.sh)"
        )]
        release_lock_fd: Option<i32>,
    },

    #[command(
        about = "Prints the command tctiSH starts in new terminals, or nothing for the shell"
    )]
    DefaultCommand {},

    #[command(about = "Fetches the host's perspective on our CWD.")]
    GetCWD {},

    #[command(about = "Sets the clock to the host's, if it is far enough out (for tctish-agent)")]
    SetClock {
        #[arg(help = "The host's time, as <seconds>.<fraction> since the epoch")]
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
            let named = name.is_some();
            let name = name.unwrap_or_else(|| mount::default_name(&mountpoint));

            // Before the picker, so that a name the app won't take doesn't cost a trip through it.
            if !mount::is_share_name(&name) {
                eprintln!(
                    "'{name}' isn't a name for a shared folder: up to 64 letters, digits, '.', \
                     '_' and '-'"
                );
                std::process::exit(1);
            }

            // If the boot is still mounting the remembered folders, wait, so this doesn't mount on
            // top of one of them.
            mount::wait_for_restore();

            if let Err(err) = mount::check_mountpoint(&mountpoint) {
                eprintln!("Failed to mount: {err:#}");
                std::process::exit(1);
            }

            // A name made up from the mountpoint can clash with a folder already shared under that
            // name. Mounting would then switch that folder for everyone using it, so refuse.
            let state = mount::share_state(&name).unwrap_or(mount::ShareState::Unknown);
            if !named && state != mount::ShareState::Unknown {
                eprintln!(
                    "A folder is already shared as '{name}'; pass --name {name} to mount that one, \
                     or another --name to pick a new one"
                );
                std::process::exit(1);
            }

            // A name given explicitly for a folder that can still be reached mounts that folder
            // again, without the picker. The app would refuse a different folder under the name
            // anyway.
            let remembered = named && state == mount::ShareState::Reachable;
            let tag = if remembered {
                mount::mount_remembered(&name, &mountpoint).map(|()| {
                    eprintln!(
                        "Mounted '{name}', the folder picked last time; run `tctictl forget {name}` \
                         to pick another."
                    );
                    name
                })
            } else {
                match ui::select_folder_as_bookmark() {
                    Ok(bookmark) => mount::mount_from_host(bookmark, name, mountpoint.clone()),
                    Err(err) => {
                        eprintln!("Couldn't select a folder to mount: {}", err);
                        std::process::exit(1);
                    }
                }
            };

            let tag = tag.unwrap_or_else(|err| {
                eprintln!("Failed to mount: {err:#}");
                std::process::exit(1);
            });

            // The mount has worked. If this fails, it just won't come back after a reboot.
            if let Err(err) = mount::record_mountpoint(&tag, &mountpoint) {
                eprintln!("Mounted, but it won't come back after a reboot: {err:#}");
            }
        }

        Commands::Mounts {} => exit_on_error(mount::list_remembered()),

        Commands::Forget { name } => exit_on_error(mount::forget(&name)),

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

        LowlevelCommands::RestoreMounts { release_lock_fd } => {
            exit_on_error(mount::restore_remembered(release_lock_fd))
        }

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
