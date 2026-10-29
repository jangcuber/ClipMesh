//! An account-free opaque relay. Host behind a TLS reverse proxy for external networks.
use crate::{Envelope, MAX_FRAME};
use anyhow::{ensure, Result};
use futures_util::{SinkExt, StreamExt};
use std::{
    collections::{HashMap, VecDeque},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{broadcast, Semaphore},
};
use tokio_tungstenite::{
    accept_hdr_async_with_config,
    tungstenite::{
        handshake::server::{ErrorResponse, Request, Response},
        protocol::WebSocketConfig,
        Message,
    },
};
const RETAIN_BYTES: usize = 16 * 1024 * 1024;
struct Room {
    tx: broadcast::Sender<String>,
    retained: VecDeque<String>,
    bytes: usize,
    peers: usize,
}
type Rooms = Arc<Mutex<HashMap<String, Room>>>;
pub async fn serve(listener: TcpListener) -> Result<()> {
    let rooms: Rooms = Arc::new(Mutex::new(HashMap::new()));
    let permits = Arc::new(Semaphore::new(128));
    loop {
        let (stream, _) = listener.accept().await?;
        let Ok(permit) = permits.clone().try_acquire_owned() else {
            continue;
        };
        let rooms = rooms.clone();
        tokio::spawn(async move {
            let _permit = permit;
            let _ = connection(stream, rooms).await;
        });
    }
}
#[allow(clippy::result_large_err)] // tungstenite handshake callback requires this concrete error response
async fn connection(stream: TcpStream, rooms: Rooms) -> Result<()> {
    let selected = Arc::new(Mutex::new(String::new()));
    let picked = selected.clone();
    let ws = tokio::time::timeout(
        Duration::from_secs(10),
        accept_hdr_async_with_config(
            stream,
            move |req: &Request,
                  response: Response|
                  -> std::result::Result<Response, ErrorResponse> {
                let group = req.uri().path().strip_prefix("/v1/ws/").unwrap_or("");
                if group.len() != 64
                    || !group
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                    || req.uri().query().is_some()
                {
                    let mut e = ErrorResponse::new(Some("invalid group path".into()));
                    *e.status_mut() = tokio_tungstenite::tungstenite::http::StatusCode::BAD_REQUEST;
                    return Err(e);
                }
                *picked.lock().unwrap() = group.into();
                Ok(response)
            },
            Some(
                WebSocketConfig::default()
                    .max_message_size(Some(MAX_FRAME))
                    .max_frame_size(Some(MAX_FRAME)),
            ),
        ),
    )
    .await??;
    let group = selected.lock().unwrap().clone();
    let (mut rx, snapshot) = {
        let mut rooms = rooms.lock().unwrap();
        ensure!(
            rooms.len() < 64 || rooms.contains_key(&group),
            "relay group limit"
        );
        let room = rooms.entry(group.clone()).or_insert_with(|| Room {
            tx: broadcast::channel(32).0,
            retained: VecDeque::new(),
            bytes: 0,
            peers: 0,
        });
        room.peers += 1;
        (room.tx.subscribe(), room.retained.clone())
    };
    let (mut sink, mut stream) = ws.split();
    let result:Result<()>=async {
        for msg in snapshot {sink.send(Message::Text(msg.into())).await?;}
        let mut window=Instant::now();let mut received=0u32;
        let mut heartbeat=tokio::time::interval(Duration::from_secs(20));
        loop {tokio::select! {
            incoming=stream.next()=> match incoming {
                Some(Ok(Message::Text(frame)))=> {
                    if window.elapsed()>Duration::from_secs(1){window=Instant::now();received=0;}
                    received+=1;ensure!(received<=30,"rate limited");
                    ensure!(frame.len()<=MAX_FRAME,"oversized frame");
                    let env:Envelope=serde_json::from_str(frame.as_ref())?;env.validate_public(&group)?;
                    let mut rooms=rooms.lock().unwrap();let room=rooms.get_mut(&group).unwrap();
                    let frame=frame.to_string();
                    // Exact retries do not consume the bounded replay window.
                    if !room.retained.iter().any(|s|s==&frame) {
                        room.bytes+=frame.len();room.retained.push_back(frame.clone());
                        while room.retained.len()>16 || room.bytes>RETAIN_BYTES {if let Some(old)=room.retained.pop_front(){room.bytes-=old.len();}}
                    }
                    let _=room.tx.send(frame);
                },
                Some(Ok(Message::Ping(data)))=>sink.send(Message::Pong(data)).await?,
                Some(Ok(Message::Pong(_)))=>{},
                Some(Ok(Message::Close(_)))|None=>break,
                Some(Ok(_))=>{},Some(Err(e))=>return Err(e.into()),
            },
            outgoing=rx.recv()=>match outgoing {Ok(text)=>sink.send(Message::Text(text.into())).await?,Err(broadcast::error::RecvError::Lagged(_))=>anyhow::bail!("slow client"),Err(_)=>break},
            _=heartbeat.tick()=>sink.send(Message::Ping(Vec::new().into())).await?,
        }}Ok(())
    }.await;
    let mut rooms = rooms.lock().unwrap();
    if let Some(room) = rooms.get_mut(&group) {
        room.peers -= 1;
        if room.peers == 0 {
            rooms.remove(&group);
        }
    }
    result
}
