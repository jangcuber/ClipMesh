use clipmesh::{Config, Group};
use serde_json::{json, Value};
use std::{path::Path, process::Stdio, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines},
    net::TcpListener,
    process::{Child, ChildStdin, ChildStdout, Command},
};
struct Host {
    child: Child,
    input: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
}
impl Host {
    fn spawn(path: &Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_clipmesh"))
            .args(["run", "--config"])
            .arg(path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let lines = BufReader::new(child.stdout.take().unwrap()).lines();
        Self {
            child,
            input,
            lines,
        }
    }
    async fn send(&mut self, v: Value) {
        self.input
            .write_all(format!("{v}\n").as_bytes())
            .await
            .unwrap();
        self.input.flush().await.unwrap();
    }
    async fn until(&mut self, mut predicate: impl FnMut(&Value) -> bool) -> Value {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let line = self
                    .lines
                    .next_line()
                    .await
                    .unwrap()
                    .expect("core exited before expected event");
                let value: Value = serde_json::from_str(&line).unwrap();
                if value["type"] == "status" {
                    eprintln!(
                        "test status {} {} peers={}",
                        value["connected"], value["transport"], value["peers"]
                    );
                }
                assert_ne!(value["type"], "error", "unexpected core error: {value}");
                if predicate(&value) {
                    return value;
                }
            }
        })
        .await
        .expect("timed out waiting for host event")
    }
    async fn connected(&mut self) {
        self.until(|v| v["type"] == "status" && v["connected"] == true)
            .await;
    }
    async fn clipboard(&mut self, text: &str) {
        let v = self.until(|v| v["type"] == "clipboard").await;
        assert_eq!(v["event"]["text"], text);
    }
    async fn quit(mut self) {
        self.send(json!({"op":"quit"})).await;
        assert!(
            tokio::time::timeout(Duration::from_secs(5), self.child.wait())
                .await
                .unwrap()
                .unwrap()
                .success()
        );
    }
}
#[tokio::test]
async fn real_host_processes_copy_pause_resume_history_and_restart() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let group = Group::create(
        "bridge".into(),
        format!("ws://{}", listener.local_addr().unwrap()),
    )
    .unwrap();
    let relay = tokio::spawn(async move { clipmesh::relay::serve(listener).await.unwrap() });
    let dir = tempfile::tempdir().unwrap();
    let a_path = dir.path().join("a.json");
    let b_path = dir.path().join("b.json");
    let c_path = dir.path().join("c.json");
    for (name, path) in [("a", &a_path), ("b", &b_path), ("c", &c_path)] {
        Config::new(group.clone(), name.into())
            .unwrap()
            .save(path)
            .unwrap();
    }
    let mut a = Host::spawn(&a_path);
    a.connected().await;
    a.send(json!({"op":"copy","text":"alpha 한글"})).await;
    a.until(|v| v["type"] == "copied").await;
    let mut b = Host::spawn(&b_path);
    b.connected().await;
    b.clipboard("alpha 한글").await;
    let mut c = Host::spawn(&c_path);
    c.connected().await;
    c.clipboard("alpha 한글").await;
    b.send(json!({"op":"pause","paused":true})).await;
    b.until(|v| v["type"] == "status" && v["paused"] == true)
        .await;
    a.send(json!({"op":"copy","text":"beta"})).await;
    a.until(|v| v["type"] == "copied").await;
    c.clipboard("beta").await;
    b.send(json!({"op":"pause","paused":false})).await;
    b.clipboard("beta").await;
    b.send(json!({"op":"history"})).await;
    let history = b.until(|v| v["type"] == "history").await;
    assert!(history["events"]
        .as_array()
        .unwrap()
        .iter()
        .any(|e| e["text"] == "beta"));
    b.quit().await;
    c.send(json!({"op":"copy","text":"gamma"})).await;
    c.until(|v| v["type"] == "copied").await;
    a.clipboard("gamma").await;
    let mut b = Host::spawn(&b_path);
    b.connected().await;
    b.clipboard("gamma").await;
    b.quit().await;
    a.quit().await;
    c.quit().await;
    relay.abort();
}

#[tokio::test]
async fn png_roundtrip_via_real_encrypted_relay() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let g = Group::create(
        "image".into(),
        format!("ws://{}", listener.local_addr().unwrap()),
    )
    .unwrap();
    let relay = tokio::spawn(async move { clipmesh::relay::serve(listener).await.unwrap() });
    let dir = tempfile::tempdir().unwrap();
    let ap = dir.path().join("a.json");
    let bp = dir.path().join("b.json");
    Config::new(g.clone(), "a".into())
        .unwrap()
        .save(&ap)
        .unwrap();
    Config::new(g, "b".into()).unwrap().save(&bp).unwrap();
    let mut a = Host::spawn(&ap);
    let mut b = Host::spawn(&bp);
    a.connected().await;
    b.connected().await;
    let png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    a.send(json!({"op":"copy_image","data":png})).await;
    a.until(|v| v["type"] == "copied").await;
    let event = b.until(|v| v["type"] == "clipboard").await;
    assert_eq!(event["event"]["mime"], "image/png");
    assert_eq!(event["event"]["text"], png);
    b.send(json!({"op":"copy","text":"after image"})).await;
    a.clipboard("after image").await;
    a.quit().await;
    b.quit().await;
    relay.abort();
}

#[tokio::test]
async fn p2p_survives_relay_shutdown_and_peer_restart() {
    // Kill an actual relay subprocess so its existing sockets disappear as well.
    let reserve = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = reserve.local_addr().unwrap();
    drop(reserve);
    let mut relay = Command::new(env!("CARGO_BIN_EXE_clipmesh"))
        .args(["relay", "--listen", &addr.to_string()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    tokio::time::sleep(Duration::from_millis(150)).await;
    let mut g = Group::create("mesh".into(), format!("ws://{addr}")).unwrap();
    g.transport = Some("p2p".into());
    let dir = tempfile::tempdir().unwrap();
    let ap = dir.path().join("a.json");
    let bp = dir.path().join("b.json");
    Config::new(g.clone(), "a".into())
        .unwrap()
        .save(&ap)
        .unwrap();
    Config::new(g, "b".into()).unwrap().save(&bp).unwrap();
    let mut a = Host::spawn(&ap);
    let mut b = Host::spawn(&bp);
    a.connected().await;
    b.connected().await;
    let status = a
        .until(|v| v["transport"] == "p2p-direct" && v["peers"] == 1)
        .await;
    assert_eq!(status["connected_peer_count"], 1);
    assert_eq!(status["known_peer_count"], 1);
    assert_eq!(status["peer_details"][0]["name"], "b");
    assert_eq!(status["peer_details"][0]["route"], "direct");
    b.until(|v| v["transport"] == "p2p-direct" && v["peers"] == 1)
        .await;
    relay.kill().await.unwrap();
    relay.wait().await.unwrap();
    a.send(json!({"op":"copy","text":"server is off 한글"}))
        .await;
    b.clipboard("server is off 한글").await;
    b.send(json!({"op":"copy","text":"reverse without server"}))
        .await;
    a.clipboard("reverse without server").await;
    let png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwbPr2HwAFOgKpyNxwqgAAAABJRU5ErkJggg==";
    a.send(json!({"op":"copy_image","data":png})).await;
    let image = b.until(|v| v["type"] == "clipboard").await;
    assert_eq!(image["event"]["mime"], "image/png");
    assert_eq!(image["event"]["text"], png);
    b.quit().await;
    tokio::time::sleep(Duration::from_millis(250)).await;
    let mut b = Host::spawn(&bp);
    b.until(|v| v["transport"] == "p2p-direct" && v["peers"] == 1)
        .await;
    b.send(json!({"op":"copy","text":"restarted without server"}))
        .await;
    a.clipboard("restarted without server").await;
    a.quit().await;
    b.quit().await;
}

impl Host {
    async fn wait_mesh(&mut self, count: u64) -> Value {
        tokio::time::timeout(Duration::from_secs(100), async {
            loop {
                let line = self
                    .lines
                    .next_line()
                    .await
                    .unwrap()
                    .expect("mesh process exited");
                let v: Value = serde_json::from_str(&line).unwrap();
                assert_ne!(v["type"], "error", "unexpected core error: {v}");
                if v["type"] == "status"
                    && v["connected_peer_count"] == count
                    && !v["self_id"].as_str().unwrap_or("").is_empty()
                {
                    return v;
                }
            }
        })
        .await
        .expect("public endpoint-ID discovery did not converge")
    }
    async fn wait_text(&mut self, text: &str) {
        self.until(|v| v["type"] == "clipboard" && v["event"]["text"] == text)
            .await;
    }
}
/// Requires the real official N0 relay + signed address lookup infrastructure.
/// No ClipMesh WS listener is ever created in this test. Run explicitly in
/// deployment validation rather than silently making offline unit tests flaky.
#[tokio::test]
#[ignore = "requires public N0 discovery/relay network access"]
async fn serverless_three_peer_seed_join_mac_off_and_all_peer_restart_new_ports() {
    let dir = tempfile::tempdir().unwrap();
    let ap = dir.path().join("a.json");
    let bp = dir.path().join("b.json");
    let cp = dir.path().join("c.json");
    let group = Group::create("serverless".into(), String::new()).unwrap();
    Config::new(group.clone(), "Mac creator".into())
        .unwrap()
        .save(&ap)
        .unwrap();
    let mut a = Host::spawn(&ap);
    let a0 = a.wait_mesh(0).await;
    let aid = a0["self_id"].as_str().unwrap().to_string();
    let invitation = clipmesh::transport::enriched_group(&ap, &group).unwrap();
    assert_eq!(invitation.seeds[0], aid);
    Config::new(invitation.clone(), "Windows peer".into())
        .unwrap()
        .save(&bp)
        .unwrap();
    let mut b = Host::spawn(&bp);
    let b1 = b.wait_mesh(1).await;
    let bid = b1["self_id"].as_str().unwrap().to_string();
    a.wait_mesh(1).await;
    // C knows only B; the encrypted peer book must teach A and C each other's IDs.
    let mut third = group.clone();
    third.seeds = vec![bid.clone()];
    Config::new(third, "Android peer".into())
        .unwrap()
        .save(&cp)
        .unwrap();
    let mut c = Host::spawn(&cp);
    let c2 = c.wait_mesh(2).await;
    let cid = c2["self_id"].as_str().unwrap().to_string();
    a.wait_mesh(2).await;
    b.wait_mesh(2).await;
    a.quit().await;
    b.wait_mesh(1).await;
    c.wait_mesh(1).await;
    b.send(json!({"op":"copy","text":"Mac off: Windows to Android 한글"}))
        .await;
    c.wait_text("Mac off: Windows to Android 한글").await;
    let png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMwbPr2HwAFOgKpyNxwqgAAAABJRU5ErkJggg==";
    c.send(json!({"op":"copy_image","data":png})).await;
    b.until(|v| {
        v["type"] == "clipboard" && v["event"]["mime"] == "image/png" && v["event"]["text"] == png
    })
    .await;
    b.quit().await;
    c.quit().await;
    // Keep endpoint secrets/IDs but remove every old route and bind a new port.
    // Both remaining devices must resolve updated signed addresses by ID.
    for path in [&bp, &cp] {
        let cache = path.with_extension(format!("{}.mesh", group.id().unwrap()));
        let mut v: Value = serde_json::from_slice(&std::fs::read(&cache).unwrap()).unwrap();
        v["port"] = json!(0);
        for peer in v["peers"].as_array_mut().unwrap() {
            peer["addrs"] = json!([]);
        }
        clipmesh::private_write(&cache, &serde_json::to_vec(&v).unwrap()).unwrap();
    }
    let mut b = Host::spawn(&bp);
    let mut c = Host::spawn(&cp);
    let b_restarted = b.wait_mesh(1).await;
    let c_restarted = c.wait_mesh(1).await;
    assert_eq!(b_restarted["self_id"], bid);
    assert_eq!(c_restarted["self_id"], cid);
    b.send(json!({"op":"copy","text":"all remaining devices restarted, Mac still off"}))
        .await;
    c.wait_text("all remaining devices restarted, Mac still off")
        .await;
    c.send(json!({"op":"copy","text":"reverse after restart"}))
        .await;
    b.wait_text("reverse after restart").await;
    b.quit().await;
    c.quit().await;
}
