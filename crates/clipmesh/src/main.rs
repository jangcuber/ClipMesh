use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use clipmesh::{Config, Group};
use serde_json::json;
use std::{net::SocketAddr, path::PathBuf};
#[derive(Parser)]
#[command(
    name = "clipmesh",
    version,
    about = "Account-free encrypted clipboard sync"
)]
struct Args {
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// Opaque WebSocket relay. External use requires a TLS reverse proxy.
    Relay {
        #[arg(long, default_value = "0.0.0.0:4243")]
        listen: SocketAddr,
    },
    Group {
        #[command(subcommand)]
        command: GroupCommand,
    },
    /// Newline JSON stdin/stdout host bridge; clipboard APIs stay in native hosts.
    Run {
        #[arg(long)]
        config: PathBuf,
    },
    /// Encrypted-frame subprocess bridge for native mobile hosts.
    Transport {
        #[arg(long)]
        config: PathBuf,
    },
    /// Observe fresh encrypted peer advertisements without joining the mesh.
    Inspect {
        #[arg(long)]
        config: PathBuf,
        #[arg(long, default_value_t = 12)]
        seconds: u64,
    },
    /// Validate a config without exposing its secret key.
    Check {
        #[arg(long)]
        config: PathBuf,
    },
}
#[derive(Subcommand)]
enum GroupCommand {
    Create {
        #[arg(long, default_value = "")]
        relay: String,
        #[arg(long, default_value = "My Sync Group")]
        name: String,
        #[arg(long)]
        config: Option<PathBuf>,
        #[arg(long, default_value = "ClipMesh device")]
        device_name: String,
    },
    Join {
        #[arg(long)]
        uri: String,
        #[arg(long)]
        config: PathBuf,
        #[arg(long, default_value = "ClipMesh device")]
        device_name: String,
    },
    Export {
        #[arg(long)]
        config: PathBuf,
        /// Exclude the optional legacy WebSocket relay from the exported invite.
        #[arg(long)]
        without_relay: bool,
    },
}
#[tokio::main]
async fn main() {
    if let Err(e) = execute().await {
        eprintln!("ClipMesh: {e:#}");
        std::process::exit(1);
    }
}
async fn execute() -> Result<()> {
    match Args::parse().command {
        Command::Relay { listen } => {
            let listener = tokio::net::TcpListener::bind(listen).await?;
            eprintln!(
                "ClipMesh opaque relay listening on {}",
                listener.local_addr()?
            );
            clipmesh::relay::serve(listener).await?;
        }
        Command::Run { config } => clipmesh::runtime::run(config).await?,
        Command::Transport { config } => clipmesh::transport::process(config).await?,
        Command::Inspect { config, seconds } => {
            println!("{}", clipmesh::transport::inspect(config, seconds).await?)
        }
        Command::Check { config } => {
            let c = Config::load(&config)?;
            println!(
                "{}",
                json!({"valid":true,"device":c.device,"group":c.active_group,"group_count":c.groups.len()})
            );
        }
        Command::Group { command } => match command {
            GroupCommand::Create {
                relay,
                name,
                config,
                device_name,
            } => {
                let group = Group::create(name, relay)?;
                if let Some(path) = config {
                    anyhow::ensure!(!path.exists(), "refusing to overwrite existing config");
                    Config::new(group.clone(), device_name)?.save(&path)?;
                }
                println!(
                    "{}",
                    json!({"uri":if group.relay.is_empty(){None}else{Some(group.pairing_uri()?)} ,"group":group.id()?,"pairing_ready":!group.relay.is_empty(),"next":"start sync, then group export --config FILE"})
                );
            }
            GroupCommand::Join {
                uri,
                config,
                device_name,
            } => {
                let group = Group::from_uri(&uri)?;
                let mut c = if config.exists() {
                    Config::load(&config)?
                } else {
                    Config::new(group.clone(), device_name)?
                };
                if let Some(existing) = c.groups.iter_mut().find(|g| g.id().ok() == group.id().ok())
                {
                    *existing = group.clone();
                } else {
                    c.groups.push(group.clone());
                }
                c.active_group = group.id()?;
                c.save(&config)?;
                println!("{}", json!({"group":c.active_group,"config":config}));
            }
            GroupCommand::Export {
                config,
                without_relay,
            } => {
                let c = Config::load(&config)?;
                let mut group = clipmesh::transport::enriched_group(
                    &config,
                    c.active().context("no active group")?,
                )?;
                if without_relay {
                    anyhow::ensure!(
                        group.transport.as_deref() == Some("p2p") && !group.seeds.is_empty(),
                        "start P2P sync before exporting a relay-free invitation"
                    );
                    group.relay.clear();
                }
                println!("{}", json!({"uri":group.pairing_uri()?}));
            }
        },
    }
    Ok(())
}
