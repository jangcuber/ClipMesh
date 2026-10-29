//! Optional QUIC mesh. WebSocket is rendezvous and a fallback, never a trust root.
use crate::{private_write, Config, Envelope, Group, MAX_FRAME};
use anyhow::{ensure, Context, Result};
use futures_util::{SinkExt, StreamExt};
use iroh::{
    endpoint::{presets, Connection},
    Endpoint, EndpointAddr, SecretKey,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::{broadcast, mpsc, watch},
};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{protocol::WebSocketConfig, Message},
};
const ALPN: &[u8] = b"clipmesh/mesh/1";
const MAX_PEERS: usize = 32;
#[derive(Serialize, Deserialize)]
struct Saved {
    secret: [u8; 32],
    #[serde(default)]
    port: u16,
    peers: Vec<EndpointAddr>,
    #[serde(default)]
    metadata: HashMap<String, PeerMetadata>,
}
#[derive(Serialize, Deserialize)]
struct Advert {
    kind: String,
    addr: EndpointAddr,
    #[serde(default, flatten)]
    metadata: PeerMetadata,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
struct PeerMetadata {
    #[serde(default)]
    name: String,
    #[serde(default)]
    device: String,
    #[serde(default)]
    platform: String,
}
impl PeerMetadata {
    fn validate(&self) -> Result<()> {
        ensure!(
            self.name.len() <= 200 && !self.name.chars().any(char::is_control),
            "invalid device name"
        );
        ensure!(
            self.device.is_empty() || uuid::Uuid::parse_str(&self.device).is_ok(),
            "invalid device identity"
        );
        ensure!(
            matches!(
                self.platform.as_str(),
                "" | "macos" | "windows" | "ios" | "android" | "linux"
            ),
            "invalid device platform"
        );
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct PeerInfo {
    pub id: String,
    pub name: String,
    pub device: String,
    pub platform: String,
    pub route: String,
}
#[derive(Clone, Debug, Default, Serialize)]
pub struct PeerStatus {
    pub connected: bool,
    pub transport: String,
    pub peers: usize,
    pub connected_peer_count: usize,
    pub known_peer_count: usize,
    pub direct_peer_count: usize,
    pub relay_peer_count: usize,
    pub self_id: String,
    pub self_name: String,
    pub peer_details: Vec<PeerInfo>,
    pub seed_ids: Vec<String>,
}
#[derive(Debug)]
pub enum Notice {
    Frame(String),
    Diagnostic {
        stage: &'static str,
        code: &'static str,
    },
    Status(PeerStatus),
}
pub struct Bridge {
    pub send: mpsc::Sender<String>,
    pub recv: mpsc::Receiver<Notice>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Bridge {
    fn drop(&mut self) {
        self.task.abort();
    }
}
#[derive(Clone, Debug)]
struct PeerHello {
    boot: String,
    addr: EndpointAddr,
    metadata: PeerMetadata,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct PeerBook {
    kind: String,
    entries: Vec<BookEntry>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct BookEntry {
    addr: EndpointAddr,
    #[serde(default, flatten)]
    metadata: PeerMetadata,
}
struct PeerLink {
    conn: Connection,
    data: watch::Sender<Option<String>>,
    control: mpsc::Sender<String>,
    boot: String,
}
const MAX_CONTROL: usize = 64 * 1024;
enum Internal {
    Data(String),
    Advert(String),
    Ws(bool),
    PeerUp(Connection, PeerHello),
    PeerDown(String, usize),
    DialDone(String),
    Diagnostic {
        stage: &'static str,
        code: &'static str,
    },
}
// Never emit error Display/Debug strings: they may contain addresses, URLs,
// response bodies, or application payloads. Only these fixed class codes leave
// the transport. Inspecting an error locally does not make its contents a log.
fn websocket_error_code(error: &tokio_tungstenite::tungstenite::Error) -> &'static str {
    use tokio_tungstenite::tungstenite::Error;
    match error {
        Error::Tls(_) => "tls",
        Error::Io(error) => {
            if error
                .get_ref()
                .is_some_and(|source| source.is::<rustls::Error>())
            {
                return "tls";
            }
            let message = error.to_string().to_ascii_lowercase();
            if message.contains("no native root ca certificates") {
                "tls-roots"
            } else if message.contains("lookup address")
                || message.contains("dns")
                || message.contains("nodename nor servname")
            {
                "dns"
            } else {
                "socket"
            }
        }
        Error::Http(_) | Error::HttpFormat(_) => "http",
        Error::Url(_) => "configuration",
        Error::ConnectionClosed | Error::AlreadyClosed => "closed",
        _ => "websocket",
    }
}
fn discovery(group: &Group) -> Result<Group> {
    use base64::Engine;
    let mut key = Sha256::new();
    key.update(b"clipmesh:discovery:1:");
    key.update(group.key_bytes()?);
    Ok(Group {
        name: group.name.clone(),
        relay: group.relay.clone(),
        key: base64::engine::general_purpose::STANDARD.encode(key.finalize()),
        transport: None,
        seeds: Vec::new(),
    })
}
fn validate_address(addr: &EndpointAddr) -> Result<()> {
    ensure!(
        addr.addrs.len() <= 16 && serde_json::to_vec(addr)?.len() <= 4096,
        "peer address too large"
    );
    Ok(())
}
fn export_ids(own: &str, ids: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut others = ids.into_iter().filter(|id| id != own).collect::<Vec<_>>();
    others.sort();
    others.dedup();
    std::iter::once(own.to_string())
        .chain(others)
        .take(MAX_PEERS)
        .collect()
}
fn peer_book(
    own: &EndpointAddr,
    own_metadata: &PeerMetadata,
    known: &HashMap<String, EndpointAddr>,
    metadata: &HashMap<String, PeerMetadata>,
) -> PeerBook {
    let mut entries = vec![BookEntry {
        addr: own.clone(),
        metadata: own_metadata.clone(),
    }];
    let mut ids = known.keys().collect::<Vec<_>>();
    ids.sort();
    for id in ids.into_iter().take(MAX_PEERS - 1) {
        if id != &own.id.to_string() {
            entries.push(BookEntry {
                addr: known[id].clone(),
                metadata: metadata.get(id).cloned().unwrap_or_default(),
            });
        }
    }
    PeerBook {
        kind: "clipmesh-peers-v1".into(),
        entries,
    }
}
fn decode_book(bytes: &[u8]) -> Result<PeerBook> {
    ensure!(bytes.len() <= MAX_CONTROL, "peer book too large");
    let book: PeerBook = serde_json::from_slice(bytes)?;
    ensure!(
        book.kind == "clipmesh-peers-v1" && book.entries.len() <= MAX_PEERS,
        "invalid peer book"
    );
    for entry in &book.entries {
        validate_address(&entry.addr)?;
        entry.metadata.validate()?;
    }
    Ok(book)
}
fn merge_book(
    book: PeerBook,
    own: &str,
    known: &mut HashMap<String, EndpointAddr>,
    metadata: &mut HashMap<String, PeerMetadata>,
) -> Result<bool> {
    let mut changed = false;
    for entry in book.entries {
        let id = entry.addr.id.to_string();
        if id == own || (!known.contains_key(&id) && known.len() >= MAX_PEERS) {
            continue;
        }
        // Third-party gossip introduces peers and fills ID-only seeds. Never
        // overwrite an owner's newer hello/address with another member's stale cache.
        if !known.contains_key(&id)
            || known
                .get(&id)
                .is_some_and(|old| old.addrs.is_empty() && !entry.addr.addrs.is_empty())
        {
            known.insert(id.clone(), entry.addr);
            changed = true;
        }
        if !metadata.contains_key(&id)
            || metadata
                .get(&id)
                .is_some_and(|m| m.name.is_empty() && !entry.metadata.name.is_empty())
        {
            metadata.insert(id, entry.metadata);
            changed = true;
        }
    }
    Ok(changed)
}
/// Export only public endpoint IDs from the existing mesh cache. Never bind an
/// extra endpoint or create a second identity while showing a pairing QR.
pub fn enriched_group(config_path: &Path, group: &Group) -> Result<Group> {
    let mut enriched = group.clone();
    if group.transport.as_deref() != Some("p2p") {
        return Ok(enriched);
    }
    let saved = std::fs::read(cache_path(config_path, group)?)
        .ok()
        .filter(|b| b.len() < 128 * 1024)
        .and_then(|b| serde_json::from_slice::<Saved>(&b).ok());
    if let Some(saved) = saved {
        let own = SecretKey::from_bytes(&saved.secret).public().to_string();
        enriched.seeds = export_ids(
            &own,
            saved
                .peers
                .into_iter()
                .map(|a| a.id.to_string())
                .chain(group.seeds.clone()),
        )
        .into_iter()
        .take(16)
        .collect();
    }
    ensure!(
        !enriched.relay.is_empty() || !enriched.seeds.is_empty(),
        "start sync before exporting a relay-free invitation"
    );
    enriched.validate()?;
    Ok(enriched)
}
fn cache_path(config: &Path, group: &Group) -> Result<PathBuf> {
    Ok(config.with_extension(format!("{}.mesh", group.id()?)))
}
fn save(
    path: &Path,
    endpoint: &Endpoint,
    peers: &HashMap<String, EndpointAddr>,
    metadata: &HashMap<String, PeerMetadata>,
) -> Result<()> {
    private_write(
        path,
        &serde_json::to_vec(&Saved {
            secret: endpoint.secret_key().to_bytes(),
            port: endpoint
                .bound_sockets()
                .iter()
                .find(|s| s.is_ipv4())
                .map(|s| s.port())
                .unwrap_or(0),
            peers: peers.values().cloned().collect(),
            metadata: metadata.clone(),
        })?,
    )
}
pub async fn start(group: Group, config_path: PathBuf) -> Result<Bridge> {
    let (send, outgoing) = mpsc::channel(8);
    let (notices, recv) = mpsc::channel(32);
    // Bind errors are returned so native hosts can explicitly fall back to their legacy socket.
    let path = cache_path(&config_path, &group)?;
    let saved: Option<Saved> = std::fs::read(&path)
        .ok()
        .filter(|b| b.len() < 128 * 1024)
        .and_then(|b| serde_json::from_slice(&b).ok());
    let secret = saved
        .as_ref()
        .map(|s| SecretKey::from_bytes(&s.secret))
        .unwrap_or_else(SecretKey::generate);
    let port = saved.as_ref().map(|s| s.port).unwrap_or(0);
    let make = |port| {
        Endpoint::builder(presets::N0)
            .secret_key(secret.clone())
            .bind_addr((std::net::Ipv4Addr::UNSPECIFIED, port))
            .map(|b| b.alpns(vec![ALPN.to_vec()]))
    };
    let endpoint = match make(port)?.bind().await {
        Ok(e) => e,
        Err(_) if port != 0 => make(0)?.bind().await?,
        Err(e) => return Err(e.into()),
    };
    let metadata = saved
        .as_ref()
        .map(|s| {
            s.metadata
                .iter()
                .filter(|(_, m)| m.validate().is_ok())
                .take(MAX_PEERS)
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect()
        })
        .unwrap_or_default();
    let config = Config::load(&config_path)?;
    let mut name = String::new();
    for c in config.name.chars().filter(|c| !c.is_control()) {
        if name.len() + c.len_utf8() > 200 {
            break;
        }
        name.push(c);
    }
    let own_metadata = PeerMetadata {
        name,
        device: config.device,
        platform: std::env::consts::OS.into(),
    };
    let mut peers: HashMap<_, _> = saved
        .map(|s| {
            s.peers
                .into_iter()
                .take(MAX_PEERS)
                .map(|a| (a.id.to_string(), a))
                .collect()
        })
        .unwrap_or_default();
    for seed in &group.seeds {
        let id = seed.parse::<iroh::EndpointId>()?;
        if id != endpoint.id() && peers.len() < MAX_PEERS {
            peers
                .entry(seed.clone())
                .or_insert_with(|| EndpointAddr::new(id));
        }
    }
    save(&path, &endpoint, &peers, &metadata)?;
    let task = tokio::spawn(async move {
        if let Err(_e) = mesh(
            group,
            path,
            endpoint,
            peers,
            metadata,
            own_metadata,
            outgoing,
            notices.clone(),
        )
        .await
        {
            let _ = notices
                .send(Notice::Status(PeerStatus {
                    transport: "unavailable".into(),
                    ..PeerStatus::default()
                }))
                .await;
        }
    });
    Ok(Bridge { send, recv, task })
}
async fn websocket(
    url: String,
    discovery: bool,
    tx: mpsc::Sender<Internal>,
    outgoing: broadcast::Sender<String>,
) {
    let mut out = outgoing.subscribe();
    let stage = if discovery {
        "websocket-discovery"
    } else {
        "websocket-data"
    };
    loop {
        let ws = tokio::time::timeout(
            Duration::from_secs(10),
            connect_async_with_config(
                &url,
                Some(
                    WebSocketConfig::default()
                        .max_frame_size(Some(MAX_FRAME))
                        .max_message_size(Some(MAX_FRAME)),
                ),
                false,
            ),
        )
        .await;
        let ws = match ws {
            Ok(Ok((ws, _))) => {
                let _ = tx
                    .send(Internal::Diagnostic {
                        stage,
                        code: "connected",
                    })
                    .await;
                Some(ws)
            }
            Ok(Err(error)) => {
                let _ = tx
                    .send(Internal::Diagnostic {
                        stage,
                        code: websocket_error_code(&error),
                    })
                    .await;
                None
            }
            Err(_) => {
                let _ = tx
                    .send(Internal::Diagnostic {
                        stage,
                        code: "timeout",
                    })
                    .await;
                None
            }
        };
        if let Some(ws) = ws {
            if !discovery {
                let _ = tx.send(Internal::Ws(true)).await;
            }
            let (mut sink, mut stream) = ws.split();
            loop {
                tokio::select! {
                    msg=out.recv()=>match msg {Ok(s)=>if sink.send(Message::Text(s.into())).await.is_err(){break;},Err(broadcast::error::RecvError::Closed)=>return,Err(_)=>break},
                    msg=stream.next()=>match msg {
                        Some(Ok(Message::Text(s)))=>{let event=if discovery {Internal::Advert(s.to_string())}else{Internal::Data(s.to_string())};if tx.send(event).await.is_err(){return;}},
                        Some(Ok(Message::Ping(p)))=>if sink.send(Message::Pong(p)).await.is_err(){break;},
                        Some(Ok(Message::Pong(_)))=>{},Some(Err(error))=>{let _=tx.send(Internal::Diagnostic{stage,code:websocket_error_code(&error)}).await;break;},_=>break,
                    }
                }
            }
        }
        if !discovery && tx.send(Internal::Ws(false)).await.is_err() {
            return;
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
        if tx.is_closed() {
            return;
        }
    }
}
fn spawn_peer(
    conn: Connection,
    mut outgoing: watch::Receiver<Option<String>>,
    mut control: mpsc::Receiver<String>,
    tx: mpsc::Sender<Internal>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let id = conn.remote_id().to_string();
        let stable_id = conn.stable_id();
        let _: Result<()> = async { loop { tokio::select! {
            changed=outgoing.changed()=>{if changed.is_err(){break;}let Some(frame)=outgoing.borrow_and_update().clone() else{continue;};
                let mut send = conn.open_uni().await?;
                tokio::time::timeout(Duration::from_secs(20),send.write_all(frame.as_bytes())).await??; send.finish()?;
            },
            frame=control.recv()=>{let Some(frame)=frame else{break;};let mut send=conn.open_uni().await?;
                tokio::time::timeout(Duration::from_secs(20),send.write_all(frame.as_bytes())).await??;send.finish()?;
            },
            stream=conn.accept_uni()=>{let mut stream=stream?;let bytes=tokio::time::timeout(Duration::from_secs(20),stream.read_to_end(MAX_FRAME)).await??;
                tx.send(Internal::Data(String::from_utf8(bytes)?)).await?;
            }
        }} Ok(()) }.await;
        conn.close(0u8.into(), b"transport closed");
        let _ = tx.send(Internal::PeerDown(id, stable_id)).await;
    })
}
#[allow(clippy::too_many_arguments)]
async fn mesh(
    group: Group,
    path: PathBuf,
    endpoint: Endpoint,
    mut known: HashMap<String, EndpointAddr>,
    mut metadata: HashMap<String, PeerMetadata>,
    own_metadata: PeerMetadata,
    mut outgoing: mpsc::Receiver<String>,
    notices: mpsc::Sender<Notice>,
) -> Result<()> {
    let discovery_group = discovery(&group)?;
    let (tx, mut rx) = mpsc::channel(32);
    let (data_tx, _) = broadcast::channel(16);
    let (advert_tx, _) = broadcast::channel(8);
    // Child tasks are aborted by an explicit guard even when the parent future is cancelled.
    let mut tasks = TaskGuard(Vec::new());
    if !group.relay.is_empty() {
        tasks.0.push(tokio::spawn(websocket(
            group.websocket_url()?,
            false,
            tx.clone(),
            data_tx.clone(),
        )));
        tasks.0.push(tokio::spawn(websocket(
            discovery_group.websocket_url()?,
            true,
            tx.clone(),
            advert_tx.clone(),
        )));
    }
    let myid = endpoint.id().to_string();
    let mut peers: HashMap<String, PeerLink> = HashMap::new();
    let boot = uuid::Uuid::new_v4().to_string();
    let mut dialing = HashSet::new();
    let mut ws_connected = false;
    let mut latest: Option<String> = None;
    let incoming_permits = std::sync::Arc::new(tokio::sync::Semaphore::new(8));
    let mut tick = tokio::time::interval(Duration::from_secs(3));
    loop {
        tokio::select! {
            frame=outgoing.recv()=>{
                let Some(frame)=frame else {break;};
                let envelope:Envelope=serde_json::from_str(&frame)?; envelope.validate_public(&group.id()?)?;
                // The transport validates group authentication before forwarding; malformed frames never cross peers.
                envelope.open(&group)?;
                update_latest(&group,&mut latest,&frame)?;
                for link in peers.values() {link.data.send_replace(Some(frame.clone()));}
                // Peers already connected receive the data only over QUIC. A socket remains for discovery.
                // If no mesh peer is available, WS supplies the legacy encrypted fallback.
                if peers.is_empty() || peers.len() < known.len() {let _=data_tx.send(frame);}
            },
            incoming=endpoint.accept()=>if let Some(incoming)=incoming {
                if let Ok(permit)=incoming_permits.clone().try_acquire_owned() {
                let tx=tx.clone();let group=group.clone();let boot=boot.clone();let own_addr=endpoint.addr();let own_metadata=own_metadata.clone(); tasks.0.push(tokio::spawn(async move {let _permit=permit;if let Ok(Ok(conn))=tokio::time::timeout(Duration::from_secs(5),incoming).await {
                    if let Ok(Ok(remote_boot))=tokio::time::timeout(Duration::from_secs(5),handshake(&conn,&group,&boot,&own_addr,&own_metadata)).await {let _=tx.send(Internal::PeerUp(conn,remote_boot)).await;}
                }}));
            } else {incoming.refuse();}
            },
            msg=rx.recv()=>match msg {
                Some(Internal::Data(frame))=>{
                    if frame.len()>MAX_FRAME {continue;}
                    let decoded=(||->Result<(Envelope,Vec<u8>)>{let env:Envelope=serde_json::from_str(&frame)?;let bytes=env.open_bytes(&group)?;Ok((env,bytes))})();
                    let Ok((env,bytes))=decoded else{continue;};
                    if let Ok(book)=decode_book(&bytes) {
                        if merge_book(book,&myid,&mut known,&mut metadata)? {save(&path,&endpoint,&known,&metadata)?;}
                        continue;
                    }
                    if env.open(&group).is_ok(){update_latest(&group,&mut latest,&frame)?; if notices.send(Notice::Frame(frame)).await.is_err(){break;}}
                },
                Some(Internal::Advert(frame))=>{
                    if frame.len()>64*1024 {continue;}
                    let parsed=(||->Result<Advert>{let env:Envelope=serde_json::from_str(&frame)?;let a:Advert=serde_json::from_slice(&env.open_bytes(&discovery_group)?)?;ensure!(a.kind=="clipmesh-peer-v1","wrong advertisement");a.metadata.validate()?;validate_address(&a.addr)?;Ok(a)})();
                    if let Ok(a)=parsed {let id=a.addr.id.to_string();if id!=myid && (known.len()<MAX_PEERS||known.contains_key(&id)) && (known.get(&id)!=Some(&a.addr)||metadata.get(&id)!=Some(&a.metadata)) {metadata.insert(id.clone(),a.metadata);known.insert(id,a.addr);save(&path,&endpoint,&known,&metadata)?;let _=notices.send(Notice::Diagnostic{stage:"discovery",code:"peer-discovered"}).await;}}
                },
                Some(Internal::Ws(connected))=>{ws_connected=connected;if connected {if let Some(s)=&latest {if peers.is_empty(){let _=data_tx.send(s.clone());}}}},
                Some(Internal::PeerUp(conn,hello))=>{
                    let id=conn.remote_id().to_string();
                    if !known.contains_key(&id)&&known.len()>=MAX_PEERS {conn.close(1u8.into(),b"peer limit");continue;}
                    if let Some(old)=peers.get(&id) {
                        let preferred=if myid<id {iroh::endpoint::Side::Client}else{iroh::endpoint::Side::Server};
                        if old.boot==hello.boot && (old.conn.side()==preferred||conn.side()!=preferred){conn.close(1u8.into(),b"duplicate");continue;}
                        old.conn.close(0u8.into(),b"replaced by peer restart");
                    }
                    known.insert(id.clone(),hello.addr);metadata.insert(id.clone(),hello.metadata);save(&path,&endpoint,&known,&metadata)?;
                    let (send,receive)=watch::channel(None);if let Some(frame)=&latest {send.send_replace(Some(frame.clone()));}
                    let(control_tx,control_rx)=mpsc::channel(1);
                    peers.insert(id,PeerLink{conn:conn.clone(),data:send,control:control_tx,boot:hello.boot});tasks.0.push(spawn_peer(conn,receive,control_rx,tx.clone()));
                    let _=notices.send(Notice::Diagnostic{stage:"quic-handshake",code:"authenticated"}).await;
                },
                Some(Internal::PeerDown(id,stable_id))=>{if peers.get(&id).is_some_and(|p|p.conn.stable_id()==stable_id){peers.remove(&id);}},
                Some(Internal::DialDone(id))=>{dialing.remove(&id);},
                Some(Internal::Diagnostic{stage,code})=>{if notices.send(Notice::Diagnostic{stage,code}).await.is_err(){break;}},None=>break,
            },
            _=tick.tick()=>{
                let ad=Advert{kind:"clipmesh-peer-v1".into(),addr:endpoint.addr(),metadata:own_metadata.clone()};
                let env=Envelope::seal_bytes(&discovery_group,&serde_json::to_vec(&ad)?)?;
                let _=advert_tx.send(serde_json::to_string(&env)?);
                for (id,addr) in &known {
                    // Both sides may redial after a restart; boot nonce + side chooses one socket.
                    if peers.contains_key(id) || dialing.contains(id) {continue;}
                    dialing.insert(id.clone());let tx=tx.clone();let endpoint=endpoint.clone();let addr=addr.clone();let id=id.clone();let group=group.clone();let boot=boot.clone();let own_addr=endpoint.addr();let own_metadata=own_metadata.clone();
                    tasks.0.push(tokio::spawn(async move {
                        match tokio::time::timeout(Duration::from_secs(12),endpoint.connect(addr,ALPN)).await {
                            Ok(Ok(conn))=>match tokio::time::timeout(Duration::from_secs(5),handshake(&conn,&group,&boot,&own_addr,&own_metadata)).await {
                                Ok(Ok(remote_boot))=>{let _=tx.send(Internal::PeerUp(conn,remote_boot)).await;},
                                Ok(Err(_))=>{let _=tx.send(Internal::Diagnostic{stage:"quic-handshake",code:"authentication"}).await;},
                                Err(_)=>{let _=tx.send(Internal::Diagnostic{stage:"quic-handshake",code:"timeout"}).await;},
                            },
                            Ok(Err(_))=>{let _=tx.send(Internal::Diagnostic{stage:"quic-dial",code:"quic"}).await;},
                            Err(_)=>{let _=tx.send(Internal::Diagnostic{stage:"quic-dial",code:"timeout"}).await;},
                        }
                        let _=tx.send(Internal::DialDone(id)).await;
                    }));
                }
                let book=peer_book(&endpoint.addr(),&own_metadata,&known,&metadata);
                let frame=serde_json::to_string(&Envelope::seal_bytes(&group,&serde_json::to_vec(&book)?)?)?;
                for link in peers.values(){let _=link.control.try_send(frame.clone());}
                let live=peers.iter().filter(|(_,p)|p.conn.close_reason().is_none()).map(|(id,p)|{
                    let c=&p.conn;
                    let route=if c.paths().iter().any(|p|p.is_selected()&&p.is_ip()){"direct"}else if c.paths().iter().any(|p|p.is_selected()&&p.is_relay()){"relay"}else{"connecting"};
                    (id.clone(),route.to_string())
                }).collect::<Vec<_>>();
                let mut status=peer_status(ws_connected,&myid,&own_metadata.name,known.len(),&metadata,live);
                status.seed_ids=export_ids(&myid,known.keys().cloned());
                if notices.send(Notice::Status(status)).await.is_err(){break;}
                tasks.0.retain(|t|!t.is_finished());
            }
        }
    }
    endpoint.close().await;
    Ok(())
}
fn peer_status(
    ws_connected: bool,
    self_id: &str,
    self_name: &str,
    known: usize,
    metadata: &HashMap<String, PeerMetadata>,
    live: Vec<(String, String)>,
) -> PeerStatus {
    let mut peer_details = live
        .into_iter()
        .map(|(id, route)| {
            let m = metadata.get(&id).cloned().unwrap_or_default();
            PeerInfo {
                id,
                name: m.name,
                device: m.device,
                platform: m.platform,
                route,
            }
        })
        .collect::<Vec<_>>();
    peer_details.sort_by(|a, b| a.id.cmp(&b.id));
    let direct = peer_details.iter().filter(|p| p.route == "direct").count();
    let relay = peer_details.iter().filter(|p| p.route == "relay").count();
    let transport = if direct > 0 {
        "p2p-direct"
    } else if !peer_details.is_empty() {
        "iroh-relay"
    } else if ws_connected {
        "websocket"
    } else {
        "reconnecting"
    };
    PeerStatus {
        connected: ws_connected || !peer_details.is_empty(),
        transport: transport.into(),
        peers: peer_details.len(),
        connected_peer_count: peer_details.len(),
        known_peer_count: known,
        direct_peer_count: direct,
        relay_peer_count: relay,
        self_id: self_id.into(),
        self_name: self_name.into(),
        peer_details,
        seed_ids: Vec::new(),
    }
}
// Authenticated boot nonce permits reconnecting the same endpoint identity before
// the previous QUIC connection's idle timeout, including when WS is unavailable.
async fn handshake(
    conn: &Connection,
    group: &Group,
    boot: &str,
    own_addr: &EndpointAddr,
    own_metadata: &PeerMetadata,
) -> Result<PeerHello> {
    let hello = Envelope::seal_bytes(
        group,
        &serde_json::to_vec(
            &json!({"kind":"clipmesh-hello-v1","boot":boot,"addr":own_addr,"metadata":own_metadata}),
        )?,
    )?;
    let bytes = serde_json::to_vec(&hello)?;
    let (mut send, mut recv) = if conn.side() == iroh::endpoint::Side::Client {
        let (mut send, recv) = conn.open_bi().await?;
        send.write_all(&bytes).await?;
        send.finish()?;
        (send, recv)
    } else {
        conn.accept_bi().await?
    };
    let remote = recv.read_to_end(MAX_CONTROL).await?;
    let env: Envelope = serde_json::from_slice(&remote)?;
    let value: Value = serde_json::from_slice(&env.open_bytes(group)?)?;
    ensure!(value["kind"] == "clipmesh-hello-v1", "invalid handshake");
    let remote_boot = value["boot"].as_str().context("boot nonce missing")?;
    uuid::Uuid::parse_str(remote_boot)?;
    // The group envelope proves membership for this authenticated QUIC endpoint.
    // Endpoint authentication itself is supplied by iroh's TLS identity.
    if conn.side() == iroh::endpoint::Side::Server {
        send.write_all(&bytes).await?;
        send.finish()?;
    }
    let addr = if let Some(addr) = value.get("addr") {
        serde_json::from_value::<EndpointAddr>(addr.clone())?
    } else {
        EndpointAddr::new(conn.remote_id())
    };
    ensure!(
        addr.id == conn.remote_id(),
        "peer address identity mismatch"
    );
    validate_address(&addr)?;
    let metadata = value
        .get("metadata")
        .map(|m| serde_json::from_value::<PeerMetadata>(m.clone()))
        .transpose()?
        .unwrap_or_default();
    metadata.validate()?;
    Ok(PeerHello {
        boot: remote_boot.into(),
        addr,
        metadata,
    })
}
fn update_latest(group: &Group, latest: &mut Option<String>, frame: &str) -> Result<()> {
    let e: Envelope = serde_json::from_str(frame)?;
    let event = e.open(group)?;
    let order = latest
        .as_ref()
        .and_then(|s| serde_json::from_str::<Envelope>(s).ok())
        .and_then(|e| e.open(group).ok());
    if order.as_ref().is_none_or(|old| event.order() > old.order()) {
        *latest = Some(frame.into());
    }
    Ok(())
}
struct TaskGuard(Vec<tokio::task::JoinHandle<()>>);
impl Drop for TaskGuard {
    fn drop(&mut self) {
        for task in &self.0 {
            task.abort();
        }
    }
}
/// Read-only presence observation: no endpoint bind, advertisements, event-room
/// subscription, cache writes, or clipboard calls. Fresh ads show presence,
/// not proof that each sender currently has a QUIC connection to every peer.
pub async fn inspect(config_path: PathBuf, seconds: u64) -> Result<Value> {
    ensure!(
        (8..=30).contains(&seconds),
        "observation must last 8..30 seconds"
    );
    let config = Config::load(&config_path)?;
    let group = config.active()?;
    let discovery_group = discovery(group)?;
    let own_id = std::fs::read(cache_path(&config_path, group)?)
        .ok()
        .filter(|b| b.len() < 128 * 1024)
        .and_then(|b| serde_json::from_slice::<Saved>(&b).ok())
        .map(|s| SecretKey::from_bytes(&s.secret).public().to_string());
    let (ws, _) = tokio::time::timeout(
        Duration::from_secs(10),
        connect_async_with_config(
            discovery_group.websocket_url()?,
            Some(
                WebSocketConfig::default()
                    .max_frame_size(Some(64 * 1024))
                    .max_message_size(Some(64 * 1024)),
            ),
            false,
        ),
    )
    .await
    .context("presence connection timeout")?
    .map_err(|error| anyhow::anyhow!("presence connection {}", websocket_error_code(&error)))?;
    let (mut sink, mut stream) = ws.split();
    let begin = tokio::time::Instant::now();
    let finish = tokio::time::sleep(Duration::from_secs(seconds));
    tokio::pin!(finish);
    let mut seen: HashMap<String, (PeerMetadata, usize)> = HashMap::new();
    loop {
        tokio::select! {
            _=&mut finish=>break,
            message=stream.next()=>match message {
                Some(Ok(Message::Text(frame)))=>{
                    if begin.elapsed()<Duration::from_secs(3){continue;}
                    let parsed=(||->Result<Advert>{let env:Envelope=serde_json::from_str(&frame)?;let a:Advert=serde_json::from_slice(&env.open_bytes(&discovery_group)?)?;ensure!(a.kind=="clipmesh-peer-v1","wrong advertisement");a.metadata.validate()?;validate_address(&a.addr)?;Ok(a)})();
                    if let Ok(a)=parsed {let id=a.addr.id.to_string();if seen.len()<MAX_PEERS||seen.contains_key(&id){let entry=seen.entry(id).or_default();entry.0=a.metadata;entry.1+=1;}}
                },
                Some(Ok(Message::Ping(p)))=>sink.send(Message::Pong(p)).await?,
                Some(Ok(Message::Pong(_)))=>{},Some(Ok(Message::Close(_)))|None=>break,Some(Err(_))=>anyhow::bail!("presence connection closed"),_=>{},
            }
        }
    }
    let _ = sink.close().await;
    let mut entries=seen.into_iter().map(|(id,(m,count))|json!({"id_prefix":id.chars().take(16).collect::<String>(),"name":m.name,"platform":m.platform,"is_self":own_id.as_ref()==Some(&id),"fresh_advertisements":count})).collect::<Vec<_>>();
    entries.sort_by(|a, b| a["id_prefix"].as_str().cmp(&b["id_prefix"].as_str()));
    Ok(
        json!({"observation_seconds":seconds,"replay_discard_seconds":3,"live_endpoint_count":entries.len(),"entries":entries,"evidence":"fresh group-authenticated advertisements; not a QUIC connectivity proof","read_only":true}),
    )
}
/// Mobile process bridge. It never accesses an OS clipboard and emits no raw contents to diagnostics.
pub async fn process(config_path: PathBuf) -> Result<()> {
    let config = Config::load(&config_path)?;
    let group = config.active()?.clone();
    let mut bridge = start(group, config_path).await?;
    let mut input = BufReader::new(tokio::io::stdin());
    let mut out = tokio::io::stdout();
    loop {
        tokio::select! {
            line=read_line(&mut input)=>{let Some(line)=line? else{break;};let v:Value=serde_json::from_slice(&line)?;
                match v["op"].as_str(){Some("quit")=>break,Some("send")=>{let frame=v["frame"].as_str().context("frame required")?;ensure!(frame.len()<=MAX_FRAME,"oversized frame");bridge.send.send(frame.to_string()).await?;},_=>anyhow::bail!("unknown operation")}
            },
            notice=bridge.recv.recv()=>{let Some(notice)=notice else{break;};let v=match notice {
                Notice::Frame(frame)=>json!({"type":"frame","frame":frame}),
            Notice::Diagnostic{stage,code}=>json!({"type":"diagnostic","stage":stage,"code":code}),
                Notice::Status(status)=>{let mut v=serde_json::to_value(&status)?;v["type"]=json!("status");v["state"]=json!(if status.connected{"connected"}else{"disconnected"});v},
            };out.write_all(format!("{v}\n").as_bytes()).await?;out.flush().await?;}
        }
    }
    Ok(())
}
async fn read_line(reader: &mut BufReader<tokio::io::Stdin>) -> Result<Option<Vec<u8>>> {
    let mut buf = Vec::new();
    loop {
        let part = reader.fill_buf().await?;
        if part.is_empty() {
            return if buf.is_empty() {
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
        ensure!(buf.len() + n <= MAX_FRAME * 2, "command too large");
        let done = part[n - 1] == b'\n';
        buf.extend_from_slice(&part[..n]);
        reader.consume(n);
        if done {
            return Ok(Some(buf));
        }
    }
}

#[cfg(test)]
mod diagnostic_tests {
    use super::*;
    #[test]
    fn diagnostic_class_codes_never_include_error_contents() {
        use tokio_tungstenite::tungstenite::Error;
        let cases = [
            (
                std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "no native root CA certificates found secret-url",
                ),
                "tls-roots",
            ),
            (
                std::io::Error::other("failed to lookup address information secret-url"),
                "dns",
            ),
            (
                std::io::Error::new(
                    std::io::ErrorKind::ConnectionRefused,
                    "private socket detail",
                ),
                "socket",
            ),
        ];
        for (error, expected) in cases {
            assert_eq!(websocket_error_code(&Error::Io(error)), expected);
        }
        let tls = std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            rustls::Error::InvalidCertificate(rustls::CertificateError::UnknownIssuer),
        );
        assert_eq!(websocket_error_code(&Error::Io(tls)), "tls");
    }
}

#[cfg(test)]
mod presence_tests {
    use super::*;
    #[test]
    fn websocket_and_cached_peers_are_not_live_device_presence() {
        let metadata = HashMap::from([(
            "offline".into(),
            PeerMetadata {
                name: "Offline phone".into(),
                device: String::new(),
                platform: "ios".into(),
            },
        )]);
        let s = peer_status(true, "self", "Mac", 3, &metadata, vec![]);
        assert!(s.connected);
        assert_eq!(s.transport, "websocket");
        assert_eq!(s.connected_peer_count, 0);
        assert_eq!(s.peers, 0);
        assert_eq!(s.known_peer_count, 3);
        assert!(s.peer_details.is_empty());
    }
    #[test]
    fn mixed_routes_names_and_legacy_advertisements_remain_compatible() {
        let metadata = HashMap::from([(
            "direct".into(),
            PeerMetadata {
                name: "Galaxy".into(),
                device: uuid::Uuid::new_v4().to_string(),
                platform: "android".into(),
            },
        )]);
        let s = peer_status(
            false,
            "self",
            "Mac",
            3,
            &metadata,
            vec![
                ("relay".into(), "relay".into()),
                ("direct".into(), "direct".into()),
            ],
        );
        assert_eq!(s.connected_peer_count, 2);
        assert_eq!(s.direct_peer_count, 1);
        assert_eq!(s.relay_peer_count, 1);
        assert_eq!(s.peer_details[0].name, "Galaxy");
        assert_eq!(s.peer_details[1].name, "");
        let id = SecretKey::generate().public();
        let old: Advert =
            serde_json::from_value(json!({"kind":"clipmesh-peer-v1","addr":EndpointAddr::new(id)}))
                .unwrap();
        assert_eq!(old.metadata, PeerMetadata::default());
        assert!(old.metadata.validate().is_ok());
        let bad = PeerMetadata {
            name: "x".repeat(201),
            ..PeerMetadata::default()
        };
        assert!(bad.validate().is_err());
        let bad = PeerMetadata {
            name: "hidden\nline".into(),
            ..PeerMetadata::default()
        };
        assert!(bad.validate().is_err());
    }
    #[tokio::test]
    async fn inspect_discards_retained_ads_and_never_publishes_or_writes_config() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let group = Group::create(
            "inspect".into(),
            format!("ws://{}", listener.local_addr().unwrap()),
        )
        .unwrap();
        let discovery = discovery(&group).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        Config::new(group.clone(), "observer".into())
            .unwrap()
            .save(&path)
            .unwrap();
        let before = std::fs::read(&path).unwrap();
        let stale = Advert {
            kind: "clipmesh-peer-v1".into(),
            addr: EndpointAddr::new(SecretKey::generate().public()),
            metadata: PeerMetadata {
                name: "stale".into(),
                ..PeerMetadata::default()
            },
        };
        let fresh = Advert {
            kind: "clipmesh-peer-v1".into(),
            addr: EndpointAddr::new(SecretKey::generate().public()),
            metadata: PeerMetadata {
                name: "fresh".into(),
                ..PeerMetadata::default()
            },
        };
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            let sealed =
                Envelope::seal_bytes(&discovery, &serde_json::to_vec(&stale).unwrap()).unwrap();
            ws.send(Message::Text(
                serde_json::to_string(&sealed).unwrap().into(),
            ))
            .await
            .unwrap();
            tokio::time::sleep(Duration::from_secs(4)).await;
            let sealed =
                Envelope::seal_bytes(&discovery, &serde_json::to_vec(&fresh).unwrap()).unwrap();
            ws.send(Message::Text(
                serde_json::to_string(&sealed).unwrap().into(),
            ))
            .await
            .unwrap();
            while let Some(message) = ws.next().await {
                match message.unwrap() {
                    Message::Text(_) => panic!("read-only observer published an advertisement"),
                    Message::Close(_) => break,
                    _ => {}
                }
            }
        });
        let result = inspect(path.clone(), 8).await.unwrap();
        server.await.unwrap();
        assert_eq!(result["live_endpoint_count"], 1);
        assert_eq!(result["entries"][0]["name"], "fresh");
        assert_eq!(before, std::fs::read(&path).unwrap());
        assert!(!cache_path(&path, &group).unwrap().exists());
    }
}

#[cfg(test)]
mod seeded_mesh_tests {
    use super::*;
    #[test]
    fn peer_books_are_bounded_authenticated_controls_not_clipboard_events() {
        let own = SecretKey::generate().public();
        let remote = SecretKey::generate().public();
        let own_addr = EndpointAddr::new(own).with_ip_addr("127.0.0.1:1234".parse().unwrap());
        let group = Group::create("mesh".into(), String::new()).unwrap();
        let book = peer_book(
            &own_addr,
            &PeerMetadata::default(),
            &HashMap::new(),
            &HashMap::new(),
        );
        let envelope = Envelope::seal_bytes(&group, &serde_json::to_vec(&book).unwrap()).unwrap();
        assert!(envelope.open(&group).is_err());
        assert!(decode_book(&envelope.open_bytes(&group).unwrap()).is_ok());
        let wrong = Group::create("wrong".into(), String::new()).unwrap();
        assert!(envelope.open_bytes(&wrong).is_err());
        let mut oversized = book.clone();
        oversized.entries = vec![oversized.entries[0].clone(); MAX_PEERS + 1];
        assert!(decode_book(&serde_json::to_vec(&oversized).unwrap()).is_err());
        let mut known = HashMap::new();
        let mut metadata = HashMap::new();
        assert!(merge_book(book, &remote.to_string(), &mut known, &mut metadata).unwrap());
        assert_eq!(known.len(), 1);
        let ids = export_ids(&remote.to_string(), known.keys().cloned());
        assert_eq!(ids[0], remote.to_string());
        assert_eq!(ids[1], own.to_string());
        let old = PeerBook {
            kind: "clipmesh-peers-v1".into(),
            entries: vec![BookEntry {
                addr: EndpointAddr::new(own),
                metadata: PeerMetadata::default(),
            }],
        };
        merge_book(old, &remote.to_string(), &mut known, &mut metadata).unwrap();
        assert_eq!(known[&own.to_string()], own_addr);
    }
    #[test]
    fn seed_export_needs_identity_and_never_writes_config_or_discloses_endpoint_secret() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let group = Group::create("mesh".into(), String::new()).unwrap();
        Config::new(group.clone(), "device".into())
            .unwrap()
            .save(&path)
            .unwrap();
        let before = std::fs::read(&path).unwrap();
        assert!(enriched_group(&path, &group).is_err());
        let secret = SecretKey::generate();
        let saved = Saved {
            secret: secret.to_bytes(),
            port: 0,
            peers: vec![],
            metadata: HashMap::new(),
        };
        private_write(
            &cache_path(&path, &group).unwrap(),
            &serde_json::to_vec(&saved).unwrap(),
        )
        .unwrap();
        let result = enriched_group(&path, &group).unwrap();
        assert_eq!(result.seeds, vec![secret.public().to_string()]);
        assert_eq!(before, std::fs::read(&path).unwrap());
        let uri = result.pairing_uri().unwrap();
        let decoded = Group::from_uri(&uri).unwrap();
        assert_eq!(decoded.key, group.key);
        assert_eq!(decoded.seeds, result.seeds);
    }
}
