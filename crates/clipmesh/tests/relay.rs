use clipmesh::{Envelope, Event, Group, Register};
use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};
type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;
async fn relay() -> (Group, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let group = Group::create("integration".into(), format!("ws://{addr}")).unwrap();
    let task = tokio::spawn(async move { clipmesh::relay::serve(listener).await.unwrap() });
    (group, task)
}
async fn next(socket: &mut Socket, group: &Group) -> Event {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match socket.next().await.unwrap().unwrap() {
                Message::Text(s) => {
                    return serde_json::from_str::<Envelope>(&s)
                        .unwrap()
                        .open(group)
                        .unwrap()
                }
                Message::Ping(data) => socket.send(Message::Pong(data)).await.unwrap(),
                _ => {}
            }
        }
    })
    .await
    .unwrap()
}
async fn send(socket: &mut Socket, group: &Group, event: &Event) {
    socket
        .send(Message::Text(
            serde_json::to_string(&Envelope::seal(group, event).unwrap())
                .unwrap()
                .into(),
        ))
        .await
        .unwrap();
}
#[tokio::test]
async fn three_peer_delivery_replay_group_isolation_and_reconnect() {
    let (group, task) = relay().await;
    let url = group.websocket_url().unwrap();
    let (mut a, _) = connect_async(&url).await.unwrap();
    let (mut b, _) = connect_async(&url).await.unwrap();
    let mut state = Register::default();
    let event = state
        .copy(
            "00000000-0000-4000-8000-000000000001",
            "안녕하세요 🦀".into(),
        )
        .unwrap();
    send(&mut a, &group, &event).await;
    assert_eq!(next(&mut a, &group).await, event);
    assert_eq!(next(&mut b, &group).await, event);
    // A peer joining after a copy receives ciphertext retained by the relay.
    let (mut c, _) = connect_async(&url).await.unwrap();
    assert_eq!(next(&mut c, &group).await, event);
    let other = Group::create("isolated".into(), group.relay.clone()).unwrap();
    let (mut isolated, _) = connect_async(other.websocket_url().unwrap()).await.unwrap();
    let second = state
        .copy("00000000-0000-4000-8000-000000000001", "second".into())
        .unwrap();
    send(&mut b, &group, &second).await;
    assert_eq!(next(&mut a, &group).await, second);
    assert_eq!(next(&mut c, &group).await, second);
    let leak = tokio::time::timeout(Duration::from_millis(150), async {
        loop {
            if let Some(Ok(Message::Text(text))) = isolated.next().await {
                return text;
            }
        }
    })
    .await;
    assert!(leak.is_err());
    b.close(None).await.unwrap();
    let (mut b, _) = connect_async(&url).await.unwrap();
    let mut restored = Register::default();
    restored.receive(next(&mut b, &group).await).unwrap();
    restored.receive(next(&mut b, &group).await).unwrap();
    assert_eq!(restored.winner, Some(second));
    task.abort();
}
#[tokio::test]
async fn rejects_invalid_path_and_malformed_envelopes() {
    let (group, task) = relay().await;
    assert!(connect_async(format!("{}/v1/ws/not-a-group", group.relay))
        .await
        .is_err());
    let (mut a, _) = connect_async(group.websocket_url().unwrap()).await.unwrap();
    a.send(Message::Text("{}".into())).await.unwrap();
    let closed = tokio::time::timeout(Duration::from_secs(2), async {
        while let Some(Ok(Message::Ping(data))) = a.next().await {
            let _ = a.send(Message::Pong(data)).await;
        }
    })
    .await;
    assert!(closed.is_ok());
    task.abort();
}
