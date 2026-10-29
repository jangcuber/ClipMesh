use crate::{Config, Envelope, Register, MAX_FRAME};
use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::io::AsyncWriteExt;
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{protocol::WebSocketConfig, Message},
};
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Command {
    Copy { text: String },
    CopyImage { data: String },
    Pause { paused: bool },
    Status,
    History,
    ClearHistory,
    Quit,
}
async fn emit(value: Value) -> Result<()> {
    let mut out = tokio::io::stdout();
    out.write_all(serde_json::to_string(&value)?.as_bytes())
        .await?;
    out.write_all(b"\n").await?;
    out.flush().await?;
    Ok(())
}
fn state_path(config: &Path, group: &str) -> PathBuf {
    config.with_extension(format!("{group}.history"))
}
fn persist(state: &Register, path: &Path, group: &crate::Group) -> Result<()> {
    state
        .save(path, group)
        .context("could not persist encrypted history")
}
fn read_command(reader: &mut BufReader<std::io::Stdin>) -> Result<Option<Command>> {
    // A bounded read avoids allocating an unbounded line from a compromised host.
    let mut line = Vec::new();
    loop {
        let part = reader.fill_buf()?;
        if part.is_empty() {
            return if line.is_empty() {
                Ok(None)
            } else {
                Err(anyhow::anyhow!("unterminated command"))
            };
        }
        let n = part
            .iter()
            .position(|b| *b == b'\n')
            .map(|n| n + 1)
            .unwrap_or(part.len());
        if line.len() + n > MAX_FRAME {
            anyhow::bail!("command too large");
        }
        let finished = part[n - 1] == b'\n';
        line.extend_from_slice(&part[..n]);
        reader.consume(n);
        if finished {
            break;
        }
    }
    Ok(Some(serde_json::from_slice(&line)?))
}
pub async fn run(config_path: PathBuf) -> Result<()> {
    let mut config = Config::load(&config_path)?;
    let group = config.active()?.clone();
    if group.transport.as_deref() == Some("p2p") {
        return run_mesh(config_path, config, group).await;
    }
    let id = group.id()?;
    let url = group.websocket_url()?;
    let history_path = state_path(&config_path, &id);
    let mut state = if history_path.exists() {
        Register::load(&history_path, &group)
            .context("encrypted history is invalid; restore or remove it explicitly")?
    } else {
        Register::default()
    };
    let mut reader = BufReader::new(std::io::stdin());
    let (commands_tx, mut commands) = tokio::sync::mpsc::channel(16);
    std::thread::spawn(move || loop {
        let command = read_command(&mut reader);
        let stop = command.as_ref().map(|c| c.is_none()).unwrap_or(true);
        if commands_tx.blocking_send(command).is_err() || stop {
            break;
        }
    });
    let mut delay = Duration::from_millis(250);
    let mut latest = state
        .winner
        .as_ref()
        .map(|e| Envelope::seal(&group, e))
        .transpose()?;
    let mut reconnect = Box::pin(tokio::time::sleep(Duration::ZERO));
    loop {
        emit(json!({"type":"status","state":"disconnected","connected":false,"paused":config.paused,"group":id,"device":config.device})).await?;
        // Keep the host responsive while connection attempts and backoff are pending.
        let connection = {
            let connect = async {
                reconnect.as_mut().await;
                tokio::time::timeout(
                    Duration::from_secs(10),
                    connect_async_with_config(
                        &url,
                        Some(
                            WebSocketConfig::default()
                                .max_message_size(Some(MAX_FRAME))
                                .max_frame_size(Some(MAX_FRAME)),
                        ),
                        false,
                    ),
                )
                .await
                .context("relay connection timed out")?
                .map_err(anyhow::Error::from)
            };
            tokio::pin!(connect);
            loop {
                tokio::select! {
                    result=&mut connect=>break result,
                    command=commands.recv()=>{
                        if handle(command.unwrap_or(Ok(None))?,&mut config,&config_path,&mut state,&history_path,&group,&mut latest,false).await?{return Ok(());}
                    }
                }
            }
        };
        let Ok((ws, _)) = connection else {
            emit(json!({"type":"status","state":"disconnected","connected":false,"paused":config.paused,"message":"Relay unavailable; retrying"})).await?;
            reconnect = Box::pin(tokio::time::sleep(delay));
            delay = (delay * 2).min(Duration::from_secs(15));
            continue;
        };
        delay = Duration::from_millis(250);
        let (mut sink, mut stream) = ws.split();
        emit(json!({"type":"status","state":"connected","connected":true,"paused":config.paused,"group":id,"device":config.device})).await?;
        if !config.paused {
            if let Some(env) = &latest {
                if sink
                    .send(Message::Text(serde_json::to_string(env)?.into()))
                    .await
                    .is_err()
                {
                    continue;
                }
            }
        }
        loop {
            tokio::select! {
                command=commands.recv()=>{
                    let command=command.unwrap_or(Ok(None))?;let resume=matches!(&command,Some(Command::Pause{paused:false}));let should_send=matches!(&command,Some(Command::Copy{..}|Command::CopyImage{..}));
                    if handle(command,&mut config,&config_path,&mut state,&history_path,&group,&mut latest,true).await?{return Ok(());}
                    if resume {break;}
                    if should_send && !config.paused {if let Some(env)=&latest {if sink.send(Message::Text(serde_json::to_string(env)?.into())).await.is_err(){break;}}}
                },
                incoming=stream.next()=>match incoming {
                    Some(Ok(Message::Text(text)))=>{
                        if config.paused {continue;}
                        let decoded=(||->Result<(Envelope,crate::Event)>{let env:Envelope=serde_json::from_str(text.as_ref())?;let event=env.open(&group)?;Ok((env,event))})();
                        match decoded {
                            Ok((env,event))=>if state.receive(event.clone())?{latest=Some(env);persist(&state,&history_path,&group)?;emit(json!({"type":"clipboard","event":event})).await?;},
                            Err(_)=>emit(json!({"type":"error","message":"Rejected invalid encrypted event"})).await?
                        }
                    },
                    Some(Ok(Message::Ping(data)))=>if sink.send(Message::Pong(data)).await.is_err(){break;},
                    Some(Ok(Message::Pong(_)))=>{},Some(Ok(Message::Close(_)))|None|Some(Err(_))=>break,Some(Ok(_))=>{}
                }
            }
        }
        reconnect = Box::pin(tokio::time::sleep(delay));
    }
}
#[allow(clippy::too_many_arguments)]
async fn handle(
    command: Option<Command>,
    config: &mut Config,
    config_path: &Path,
    state: &mut Register,
    history_path: &Path,
    group: &crate::Group,
    latest: &mut Option<Envelope>,
    connected: bool,
) -> Result<bool> {
    let Some(command) = command else {
        return Ok(true);
    };
    match command {
        Command::Quit=>return Ok(true),
        Command::Copy{text}=>{
            if config.paused {emit(json!({"type":"error","message":"Sync paused"})).await?;return Ok(false);}
            match state.copy(&config.device,text){Ok(event)=>{*latest=Some(Envelope::seal(group,&event)?);persist(state,history_path,group)?;emit(json!({"type":"copied","id":event.id,"clock":event.clock})).await?},Err(e)=>emit(json!({"type":"error","message":e.to_string()})).await?}
        },
        Command::CopyImage{data}=>{
            if config.paused {emit(json!({"type":"error","message":"Sync paused"})).await?;return Ok(false);}
            match state.copy_image(&config.device,data){Ok(event)=>{*latest=Some(Envelope::seal(group,&event)?);persist(state,history_path,group)?;emit(json!({"type":"copied","id":event.id,"clock":event.clock})).await?},Err(e)=>emit(json!({"type":"error","message":e.to_string()})).await?}
        },
        Command::Pause{paused}=>{config.paused=paused;config.save(config_path)?;emit(json!({"type":"status","state":if connected {"connected"}else{"disconnected"},"connected":connected,"paused":paused})).await?},
        Command::Status=>emit(json!({"type":"status","state":if connected {"connected"}else{"disconnected"},"connected":connected,"paused":config.paused,"group":config.active_group,"device":config.device})).await?,
        Command::History=>emit(json!({"type":"history","events":state.history})).await?,
        Command::ClearHistory=>{state.history.clear();persist(state,history_path,group)?;emit(json!({"type":"history","events":[]})).await?},
    }
    Ok(false)
}

async fn run_mesh(config_path: PathBuf, mut config: Config, group: crate::Group) -> Result<()> {
    use crate::transport::{self, Notice};
    let id = group.id()?;
    let history_path = state_path(&config_path, &id);
    let mut state = if history_path.exists() {
        Register::load(&history_path, &group)?
    } else {
        Register::default()
    };
    let mut latest = state
        .winner
        .as_ref()
        .map(|e| Envelope::seal(&group, e))
        .transpose()?;
    let mut bridge = transport::start(group.clone(), config_path.clone()).await?;
    let mut reader = BufReader::new(std::io::stdin());
    let (tx, mut commands) = tokio::sync::mpsc::channel(16);
    std::thread::spawn(move || loop {
        let c = read_command(&mut reader);
        let stop = c.as_ref().map(|c| c.is_none()).unwrap_or(true);
        if tx.blocking_send(c).is_err() || stop {
            break;
        }
    });
    let mut connected = false;
    if !config.paused {
        if let Some(e) = &latest {
            bridge.send.send(serde_json::to_string(e)?).await?;
        }
    }
    loop {
        tokio::select! {
            command=commands.recv()=>{
                let command=command.unwrap_or(Ok(None))?;
                let send=matches!(&command,Some(Command::Copy{..}|Command::CopyImage{..}|Command::Pause{paused:false}));
                if handle(command,&mut config,&config_path,&mut state,&history_path,&group,&mut latest,connected).await?{return Ok(());}
                if send&&!config.paused {if let Some(e)=&latest {bridge.send.send(serde_json::to_string(e)?).await?;}}
            },
            notice=bridge.recv.recv()=>match notice {
                Some(Notice::Status(status))=>{connected=status.connected;let mut v=serde_json::to_value(&status)?;v["type"]=json!("status");v["state"]=json!(if connected{"connected"}else{"disconnected"});v["paused"]=json!(config.paused);v["group"]=json!(id);v["device"]=json!(config.device);emit(v).await?;},
                Some(Notice::Diagnostic{stage,code})=>emit(json!({"type":"diagnostic","stage":stage,"code":code})).await?,
            Some(Notice::Frame(frame))=>{
                    if config.paused {continue;}
                    let env:Envelope=serde_json::from_str(&frame)?;let event=env.open(&group)?;
                    if state.receive(event.clone())? {latest=Some(env);persist(&state,&history_path,&group)?;emit(json!({"type":"clipboard","event":event})).await?;}
                },None=>anyhow::bail!("P2P transport exited"),
            }
        }
    }
}
