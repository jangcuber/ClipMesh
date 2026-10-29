//! ClipMesh v1: encrypted group protocol and deterministic clipboard register.
use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use anyhow::{bail, ensure, Context, Result};
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{collections::VecDeque, path::Path};
use uuid::Uuid;

pub mod relay;
pub mod runtime;
pub mod transport;
pub const MAX_TEXT: usize = 1024 * 1024;
pub const MAX_IMAGE: usize = 8 * 1024 * 1024;
pub const MAX_FRAME: usize = 24 * 1024 * 1024;
pub const MAX_CLOCK: u64 = (1u64 << 53) - 1;
pub const HISTORY_LIMIT: usize = 100;
const MAX_HISTORY_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Group {
    pub name: String,
    pub relay: String,
    pub key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transport: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub seeds: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Pairing {
    v: u8,
    name: String,
    relay: String,
    key: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    transport: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    seeds: Vec<String>,
}
impl Group {
    pub fn create(name: String, relay: String) -> Result<Self> {
        let mut key = [0u8; 32];
        OsRng.fill_bytes(&mut key);
        let serverless = relay.is_empty();
        let group = Self {
            name,
            relay,
            key: STANDARD.encode(key),
            transport: if serverless { Some("p2p".into()) } else { None },
            seeds: Vec::new(),
        };
        group.validate()?;
        Ok(group)
    }
    pub fn key_bytes(&self) -> Result<[u8; 32]> {
        STANDARD
            .decode(&self.key)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("group key must be 32 bytes"))
    }
    pub fn id(&self) -> Result<String> {
        Ok(hex::encode(Sha256::digest(self.key_bytes()?)))
    }
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.name.trim().is_empty() && self.name.len() <= 200,
            "invalid group name"
        );
        self.key_bytes()?;
        ensure!(
            self.transport.as_deref().is_none_or(|t| t == "p2p"),
            "unsupported transport"
        );
        ensure!(self.seeds.len() <= 32, "too many seed endpoints");
        for seed in &self.seeds {
            ensure!(
                seed.len() == 64
                    && seed
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
                "invalid seed endpoint"
            );
            seed.parse::<iroh::EndpointId>()?;
        }
        if self.relay.is_empty() {
            ensure!(
                self.transport.as_deref() == Some("p2p"),
                "relay-free groups require P2P"
            );
            return Ok(());
        }
        let u = url::Url::parse(&self.relay)?;
        ensure!(
            matches!(u.scheme(), "ws" | "wss") && u.host_str().is_some(),
            "relay must be ws:// or wss://"
        );
        ensure!(
            u.username().is_empty()
                && u.password().is_none()
                && u.query().is_none()
                && u.fragment().is_none(),
            "relay must not contain credentials, query, or fragment"
        );
        ensure!(
            u.path().is_empty() || u.path() == "/",
            "relay URL must use the root path"
        );
        Ok(())
    }
    pub fn websocket_url(&self) -> Result<String> {
        self.validate()?;
        ensure!(!self.relay.is_empty(), "group has no WebSocket relay");
        Ok(format!(
            "{}/v1/ws/{}",
            self.relay.trim_end_matches('/'),
            self.id()?
        ))
    }
    pub fn pairing_uri(&self) -> Result<String> {
        self.validate()?;
        Ok(format!(
            "clipmesh://join#{}",
            URL_SAFE_NO_PAD.encode(serde_json::to_vec(&Pairing {
                v: 1,
                name: self.name.clone(),
                relay: self.relay.clone(),
                key: self.key.clone(),
                transport: self.transport.clone(),
                seeds: self.seeds.clone()
            })?)
        ))
    }
    pub fn from_uri(uri: &str) -> Result<Self> {
        ensure!(uri.len() <= 8192, "pairing URI too large");
        let encoded = uri
            .trim()
            .strip_prefix("clipmesh://join#")
            .context("invalid pairing URI")?;
        let p: Pairing = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(encoded)?)?;
        ensure!(p.v == 1, "unsupported pairing version");
        let g = Self {
            name: p.name,
            relay: p.relay,
            key: p.key,
            transport: p.transport,
            seeds: p.seeds,
        };
        g.validate()?;
        Ok(g)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Config {
    pub v: u8,
    pub device: String,
    pub name: String,
    pub groups: Vec<Group>,
    pub active_group: String,
    #[serde(default)]
    pub paused: bool,
}
impl Config {
    pub fn new(group: Group, name: String) -> Result<Self> {
        Ok(Self {
            v: 1,
            device: Uuid::new_v4().to_string(),
            name,
            active_group: group.id()?,
            groups: vec![group],
            paused: false,
        })
    }
    pub fn active(&self) -> Result<&Group> {
        ensure!(self.v == 1, "unsupported config version");
        Uuid::parse_str(&self.device)?;
        ensure!(
            !self.groups.is_empty() && self.groups.len() <= 64,
            "invalid group count"
        );
        for g in &self.groups {
            g.validate()?;
        }
        self.groups
            .iter()
            .find(|g| g.id().ok().as_ref() == Some(&self.active_group))
            .context("active group not found")
    }
    pub fn load(path: &Path) -> Result<Self> {
        let bytes = std::fs::read(path)?;
        ensure!(bytes.len() <= 1024 * 1024, "config too large");
        let c: Self = serde_json::from_slice(&bytes)?;
        c.active()?;
        Ok(c)
    }
    pub fn save(&self, path: &Path) -> Result<()> {
        self.active()?;
        private_write(path, &serde_json::to_vec_pretty(self)?)
    }
}
/// Atomic replacement; secrets are owner-readable on Unix. Windows relies on the profile ACL.
pub fn private_write(path: &Path, data: &[u8]) -> Result<()> {
    use std::io::Write;
    if let Some(p) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(p)?;
    }
    let tmp = path.with_extension(format!("{}.tmp", Uuid::new_v4()));
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    let mut f = opts.open(&tmp)?;
    f.write_all(data)?;
    f.sync_all()?;
    drop(f);
    std::fs::rename(&tmp, path)?;
    Ok(())
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Event {
    pub v: u8,
    pub id: String,
    pub device: String,
    pub clock: u64,
    pub created_ms: u64,
    pub mime: String,
    pub text: String,
}
impl Event {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.v == 1, "unsupported event version");
        Uuid::parse_str(&self.id)?;
        Uuid::parse_str(&self.device)?;
        ensure!(self.clock > 0 && self.clock < MAX_CLOCK, "invalid clock");
        match self.mime.as_str() {
            "text/plain" => ensure!(self.text.len() <= MAX_TEXT, "text exceeds 1 MiB"),
            "image/png" => {
                validate_png_base64(&self.text)?;
            }
            _ => bail!("unsupported clipboard MIME type"),
        }
        Ok(())
    }
    pub fn order(&self) -> (u64, &str, &str) {
        (self.clock, &self.device, &self.id)
    }
}
/// Header limits are checked before native decoding, including decompression dimensions.
pub fn validate_png_base64(encoded: &str) -> Result<Vec<u8>> {
    ensure!(
        encoded.len() <= MAX_IMAGE.div_ceil(3) * 4,
        "image exceeds 8 MiB"
    );
    let bytes = STANDARD.decode(encoded)?;
    ensure!(
        bytes.len() >= 33 && bytes.len() <= MAX_IMAGE,
        "invalid PNG size"
    );
    ensure!(
        &bytes[..8] == b"\x89PNG\r\n\x1a\n"
            && bytes[8..12] == [0, 0, 0, 13]
            && &bytes[12..16] == b"IHDR",
        "invalid PNG header"
    );
    let w = u32::from_be_bytes(bytes[16..20].try_into()?);
    let h = u32::from_be_bytes(bytes[20..24].try_into()?);
    ensure!(
        w > 0 && h > 0 && w <= 16384 && h <= 16384 && u64::from(w) * u64::from(h) <= 40_000_000,
        "PNG dimensions exceed limit"
    );
    Ok(bytes)
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Envelope {
    pub v: u8,
    pub group: String,
    pub nonce: String,
    pub ciphertext: String,
}
impl Envelope {
    pub fn seal(group: &Group, event: &Event) -> Result<Self> {
        event.validate()?;
        Self::seal_bytes(group, &serde_json::to_vec(event)?)
    }
    pub fn seal_bytes(group: &Group, bytes: &[u8]) -> Result<Self> {
        let mut nonce = [0u8; 12];
        OsRng.fill_bytes(&mut nonce);
        Self::seal_nonce(group, bytes, nonce)
    }
    pub fn seal_nonce(group: &Group, bytes: &[u8], nonce: [u8; 12]) -> Result<Self> {
        let id = group.id()?;
        let aad = format!("clipmesh:v1:{id}");
        let cipher = Aes256Gcm::new_from_slice(&group.key_bytes()?)
            .map_err(|_| anyhow::anyhow!("invalid key"))?;
        let ct = cipher
            .encrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: bytes,
                    aad: aad.as_bytes(),
                },
            )
            .map_err(|_| anyhow::anyhow!("encryption failed"))?;
        Ok(Self {
            v: 1,
            group: id,
            nonce: STANDARD.encode(nonce),
            ciphertext: STANDARD.encode(ct),
        })
    }
    pub fn open_bytes(&self, group: &Group) -> Result<Vec<u8>> {
        ensure!(
            self.v == 1 && self.group == group.id()?,
            "wrong group/version"
        );
        ensure!(
            self.ciphertext.len() <= MAX_HISTORY_BYTES,
            "ciphertext too large"
        );
        ensure!(STANDARD.decode(&self.nonce)?.len() == 12, "invalid nonce");
        let nonce = STANDARD.decode(&self.nonce)?;
        let ct = STANDARD.decode(&self.ciphertext)?;
        let cipher = Aes256Gcm::new_from_slice(&group.key_bytes()?)
            .map_err(|_| anyhow::anyhow!("invalid key"))?;
        cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &ct,
                    aad: format!("clipmesh:v1:{}", self.group).as_bytes(),
                },
            )
            .map_err(|_| anyhow::anyhow!("authentication failed"))
    }
    pub fn open(&self, group: &Group) -> Result<Event> {
        self.validate_public(&group.id()?)?;
        let e: Event = serde_json::from_slice(&self.open_bytes(group)?)?;
        e.validate()?;
        Ok(e)
    }
    pub fn validate_public(&self, expected: &str) -> Result<()> {
        ensure!(self.v == 1 && self.group == expected, "wrong group/version");
        ensure!(STANDARD.decode(&self.nonce)?.len() == 12, "invalid nonce");
        ensure!(
            self.ciphertext.len() <= MAX_FRAME && STANDARD.decode(&self.ciphertext)?.len() >= 16,
            "invalid ciphertext size"
        );
        Ok(())
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Register {
    pub clock: u64,
    pub winner: Option<Event>,
    pub history: VecDeque<Event>,
}
impl Register {
    /// Receiving a valid old event advances logical time, but does not replace a newer clipboard.
    pub fn receive(&mut self, event: Event) -> Result<bool> {
        event.validate()?;
        if self.history.iter().any(|e| e.id == event.id)
            || self.winner.as_ref().is_some_and(|e| e.id == event.id)
        {
            return Ok(false);
        }
        self.clock = self
            .clock
            .max(event.clock)
            .checked_add(1)
            .context("clock exhausted")?;
        ensure!(self.clock < MAX_CLOCK, "clock exhausted");
        let newer = self
            .winner
            .as_ref()
            .is_none_or(|w| event.order() > w.order());
        self.history.push_front(event.clone());
        self.history.truncate(HISTORY_LIMIT);
        while self.history.iter().map(|e| e.text.len()).sum::<usize>() > 4 * 1024 * 1024 {
            self.history.pop_back();
        }
        if newer {
            self.winner = Some(event);
        }
        Ok(newer)
    }
    pub fn copy(&mut self, device: &str, text: String) -> Result<Event> {
        self.copy_content(device, "text/plain", text)
    }
    pub fn copy_image(&mut self, device: &str, data: String) -> Result<Event> {
        validate_png_base64(&data)?;
        self.copy_content(device, "image/png", data)
    }
    fn copy_content(&mut self, device: &str, mime: &str, text: String) -> Result<Event> {
        if mime == "text/plain" && text.len() > MAX_TEXT {
            bail!("text exceeds 1 MiB");
        }
        ensure!(
            !text.contains("clipmesh://join#"),
            "Pairing invitations are excluded from clipboard sync"
        );
        let e = Event {
            v: 1,
            id: Uuid::new_v4().to_string(),
            device: device.into(),
            clock: self.clock.checked_add(1).context("clock exhausted")?,
            created_ms: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_millis() as u64,
            mime: mime.into(),
            text,
        };
        self.receive(e.clone())?;
        Ok(e)
    }
    pub fn load(path: &Path, group: &Group) -> Result<Self> {
        let bytes = std::fs::read(path)?;
        ensure!(bytes.len() <= MAX_HISTORY_BYTES, "history too large");
        let env: Envelope = serde_json::from_slice(&bytes)?;
        let state: Self = serde_json::from_slice(&env.open_bytes(group)?)?;
        ensure!(
            state.clock < MAX_CLOCK && state.history.len() <= HISTORY_LIMIT,
            "invalid saved register"
        );
        for e in &state.history {
            e.validate()?;
        }
        if let Some(e) = &state.winner {
            e.validate()?;
        }
        Ok(state)
    }
    pub fn save(&self, path: &Path, group: &Group) -> Result<()> {
        private_write(
            path,
            &serde_json::to_vec(&Envelope::seal_bytes(group, &serde_json::to_vec(self)?)?)?,
        )
    }
}
