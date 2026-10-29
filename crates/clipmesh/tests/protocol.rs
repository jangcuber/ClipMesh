use clipmesh::{Config, Envelope, Event, Group, Register, MAX_TEXT};
use serde::Deserialize;
#[derive(Deserialize)]
#[allow(non_snake_case)]
struct Vector {
    group: Group,
    groupId: String,
    uri: String,
    event: Event,
    envelope: Envelope,
}
fn vector() -> Vector {
    serde_json::from_str(include_str!("v1-vector.json")).unwrap()
}
#[test]
fn interoperable_node_aes_gcm_vector_and_pairing() {
    let v = vector();
    assert_eq!(v.group.id().unwrap(), v.groupId);
    assert_eq!(v.group.pairing_uri().unwrap(), v.uri);
    assert_eq!(Group::from_uri(&v.uri).unwrap().key, v.group.key);
    assert_eq!(v.envelope.open(&v.group).unwrap(), v.event);
    let sealed = Envelope::seal_nonce(
        &v.group,
        &serde_json::to_vec(&v.event).unwrap(),
        std::array::from_fn(|i| i as u8),
    )
    .unwrap();
    assert_eq!(sealed.ciphertext, v.envelope.ciphertext);
}
#[test]
fn rejects_tampering_wrong_group_nonce_and_oversize() {
    let v = vector();
    let mut e = v.envelope.clone();
    e.ciphertext.replace_range(0..1, "A");
    assert!(e.open(&v.group).is_err());
    let g = Group::create("other".into(), v.group.relay.clone()).unwrap();
    assert!(v.envelope.open(&g).is_err());
    let mut e = v.envelope.clone();
    e.nonce = "AAAA".into();
    assert!(e.open(&v.group).is_err());
    let mut e = v.event.clone();
    e.text = "x".repeat(MAX_TEXT + 1);
    assert!(Envelope::seal(&v.group, &e).is_err());
}
#[test]
fn concurrent_registers_converge_independent_of_arrival() {
    let v = vector();
    let mut a = v.event.clone();
    let mut b = v.event;
    b.id = "00000000-0000-4000-8000-000000000003".into();
    b.device = "00000000-0000-4000-8000-000000000004".into();
    b.text = "winner".into();
    let mut left = Register::default();
    let mut right = Register::default();
    left.receive(a.clone()).unwrap();
    left.receive(b.clone()).unwrap();
    right.receive(b.clone()).unwrap();
    right.receive(a.clone()).unwrap();
    assert_eq!(left.winner, right.winner);
    assert_eq!(left.winner.as_ref().unwrap().text, "winner");
    let clock = right.clock;
    assert!(!right.receive(a.clone()).unwrap());
    assert_eq!(right.clock, clock);
    a.id = "00000000-0000-4000-8000-000000000005".into();
    assert!(!right.receive(a).unwrap());
    assert!(right.clock > clock);
}
#[test]
fn encrypted_state_and_owner_only_config_roundtrip() {
    let v = vector();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("config.json");
    let c = Config::new(v.group.clone(), "test".into()).unwrap();
    c.save(&path).unwrap();
    assert_eq!(Config::load(&path).unwrap().device, c.device);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    let mut s = Register::default();
    s.receive(v.event.clone()).unwrap();
    let history = dir.path().join("history");
    s.save(&history, &v.group).unwrap();
    assert!(!std::fs::read_to_string(&history)
        .unwrap()
        .contains(&v.event.text));
    assert_eq!(Register::load(&history, &v.group).unwrap().winner, s.winner);
}
#[test]
fn pairing_secret_is_never_copied() {
    let v = vector();
    let mut s = Register::default();
    assert!(s.copy(&v.event.device, format!("  {}\n", v.uri)).is_err());
    assert!(s
        .copy(&v.event.device, format!("help text\n{}\nfooter", v.uri))
        .is_err());
    assert!(s.winner.is_none());
}
#[test]
fn invalid_invites_are_rejected() {
    assert!(Group::from_uri("clipmesh://join#AAAA").is_err());
    assert!(Group::create("test".into(), "http://host".into()).is_err());
    assert!(Group::create("test".into(), "ws://host/path".into()).is_err());
}

#[test]
fn wss_has_an_installed_crypto_provider() {
    // Enabling rustls transport alone does not select a provider. This builder
    // panics if the binary can only support ws:// despite advertising wss://.
    let _config = rustls::ClientConfig::builder()
        .with_root_certificates(rustls::RootCertStore::empty())
        .with_no_client_auth();
}

#[test]
fn png_events_encrypt_validate_and_preserve_order() {
    use base64::{engine::general_purpose::STANDARD, Engine};
    let png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    let v = vector();
    let mut a = Register::default();
    let event = a.copy_image(&v.event.device, png.into()).unwrap();
    assert_eq!(event.mime, "image/png");
    assert_eq!(
        Envelope::seal(&v.group, &event)
            .unwrap()
            .open(&v.group)
            .unwrap(),
        event
    );
    assert!(a
        .copy_image(&v.event.device, STANDARD.encode(b"not an image"))
        .is_err());
    let mut bytes = STANDARD.decode(png).unwrap();
    bytes[16..20].copy_from_slice(&20000u32.to_be_bytes());
    assert!(a
        .copy_image(&v.event.device, STANDARD.encode(bytes))
        .is_err());
    assert!(a
        .copy_image(&v.event.device, "A".repeat(12 * 1024 * 1024))
        .is_err());
    let text = a.copy(&v.event.device, "after image".into()).unwrap();
    assert!(text.order() > event.order());
}
#[test]
fn p2p_capability_roundtrips_without_changing_legacy_vector() {
    let mut g = vector().group;
    g.transport = Some("p2p".into());
    let parsed = Group::from_uri(&g.pairing_uri().unwrap()).unwrap();
    assert_eq!(parsed.transport.as_deref(), Some("p2p"));
    g.transport = Some("unknown".into());
    assert!(g.validate().is_err());
}

#[test]
fn independent_node_png_golden_vector() {
    let v: Vector = serde_json::from_str(include_str!("v1-image-vector.json")).unwrap();
    assert_eq!(v.envelope.open(&v.group).unwrap(), v.event);
    let e = Envelope::seal_nonce(
        &v.group,
        &serde_json::to_vec(&v.event).unwrap(),
        std::array::from_fn(|i| i as u8),
    )
    .unwrap();
    assert_eq!(e.ciphertext, v.envelope.ciphertext);
}

#[test]
fn relay_free_seed_invitations_are_bounded_and_legacy_vectors_stay_identical() {
    let mut group = Group::create("no Mac server".into(), String::new()).unwrap();
    assert_eq!(group.transport.as_deref(), Some("p2p"));
    group.seeds = vec![iroh::SecretKey::generate().public().to_string()];
    let parsed = Group::from_uri(&group.pairing_uri().unwrap()).unwrap();
    assert_eq!(parsed.seeds, group.seeds);
    assert_eq!(parsed.relay, "");
    assert!(group.websocket_url().is_err());
    group.transport = None;
    assert!(group.validate().is_err());
    group.transport = Some("p2p".into());
    group.seeds = vec!["A".repeat(64)];
    assert!(group.validate().is_err());
    group.seeds = vec![iroh::SecretKey::generate().public().to_string(); 33];
    assert!(group.validate().is_err());
}
