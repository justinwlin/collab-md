use base64::prelude::*;
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

use crate::patch::PatchOp;

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PhxMessage {
    topic: String,
    event: String,
    payload: Value,
    #[serde(rename = "ref")]
    msg_ref: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    join_ref: Option<String>,
}

#[derive(Debug)]
pub enum ChannelEvent {
    DocState {
        document: String,
        version: u64,
        crdt_updates: Vec<Vec<u8>>,
    },
    DocChange {
        document: String,
        author: String,
        version: u64,
    },
    DocPatch {
        ops: Vec<PatchOp>,
        author: String,
        version: u64,
    },
    CrdtUpdate {
        update: Vec<u8>,
        author: String,
        version: u64,
    },
    PatchRejected {
        document: String,
        version: u64,
    },
    UserJoined {
        username: String,
        users: Vec<String>,
    },
    UserLeft {
        username: String,
        users: Vec<String>,
    },
    Error {
        reason: String,
    },
}

pub struct PhoenixChannel {
    outgoing_tx: mpsc::UnboundedSender<Message>,
    topic: String,
    join_ref: String,
    ref_counter: u64,
}

impl PhoenixChannel {
    /// Connect to a Phoenix channel over WebSocket.
    /// Returns the channel handle and a receiver for incoming events.
    pub async fn connect(
        server_url: &str,
        username: &str,
        topic: &str,
    ) -> Result<(Self, mpsc::UnboundedReceiver<ChannelEvent>), Box<dyn std::error::Error>> {
        let ws_url = build_ws_url(server_url, username);
        let (ws_stream, _) = connect_async(&ws_url).await?;
        let (write, read) = ws_stream.split();

        let (outgoing_tx, outgoing_rx) = mpsc::unbounded_channel::<Message>();
        let (event_tx, event_rx) = mpsc::unbounded_channel::<ChannelEvent>();

        tokio::spawn(write_loop(write, outgoing_rx));
        tokio::spawn(read_loop(read, event_tx));

        let hb_tx = outgoing_tx.clone();
        tokio::spawn(heartbeat_loop(hb_tx));

        let join_ref = "1".to_string();

        let channel = PhoenixChannel {
            outgoing_tx,
            topic: topic.to_string(),
            join_ref: join_ref.clone(),
            ref_counter: 1,
        };

        channel.send_raw(PhxMessage {
            topic: topic.to_string(),
            event: "phx_join".to_string(),
            payload: serde_json::json!({"username": username}),
            msg_ref: Some(join_ref),
            join_ref: None,
        })?;

        Ok((channel, event_rx))
    }

    fn next_ref(&mut self) -> String {
        self.ref_counter += 1;
        self.ref_counter.to_string()
    }

    fn send_raw(&self, msg: PhxMessage) -> Result<(), Box<dyn std::error::Error>> {
        let text = serde_json::to_string(&msg)?;
        self.outgoing_tx
            .send(Message::Text(text))
            .map_err(|e| format!("send failed: {}", e))?;
        Ok(())
    }

    /// Send a full document update (fallback for non-CRDT updates).
    pub fn send_update(
        &mut self,
        document: &str,
        author: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let msg_ref = self.next_ref();
        self.send_raw(PhxMessage {
            topic: self.topic.clone(),
            event: "doc:update".to_string(),
            payload: serde_json::json!({
                "document": document,
                "author": author,
            }),
            msg_ref: Some(msg_ref),
            join_ref: Some(self.join_ref.clone()),
        })
    }

    /// Send a diff patch to the server (legacy, kept for backward compatibility).
    #[allow(dead_code)]
    pub fn send_patch(
        &mut self,
        ops: &[PatchOp],
        author: &str,
        base_version: u64,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let msg_ref = self.next_ref();
        self.send_raw(PhxMessage {
            topic: self.topic.clone(),
            event: "doc:patch".to_string(),
            payload: serde_json::json!({
                "ops": ops,
                "author": author,
                "base_version": base_version,
            }),
            msg_ref: Some(msg_ref),
            join_ref: Some(self.join_ref.clone()),
        })
    }

    /// Send a CRDT binary update to the server.
    pub fn send_crdt_update(
        &mut self,
        update: &[u8],
        text: &str,
        author: &str,
    ) -> Result<(), Box<dyn std::error::Error>> {
        let msg_ref = self.next_ref();
        self.send_raw(PhxMessage {
            topic: self.topic.clone(),
            event: "doc:crdt_update".to_string(),
            payload: serde_json::json!({
                "update": BASE64_STANDARD.encode(update),
                "text": text,
                "author": author,
            }),
            msg_ref: Some(msg_ref),
            join_ref: Some(self.join_ref.clone()),
        })
    }
}

fn build_ws_url(server_url: &str, username: &str) -> String {
    let base = if server_url.starts_with("ws://") || server_url.starts_with("wss://") {
        server_url.to_string()
    } else {
        server_url
            .replace("https://", "wss://")
            .replace("http://", "ws://")
    };
    format!("{}/socket/websocket?username={}", base, username)
}

async fn write_loop(
    mut sink: SplitSink<WsStream, Message>,
    mut rx: mpsc::UnboundedReceiver<Message>,
) {
    while let Some(msg) = rx.recv().await {
        if sink.send(msg).await.is_err() {
            break;
        }
    }
}

async fn read_loop(
    mut stream: SplitStream<WsStream>,
    tx: mpsc::UnboundedSender<ChannelEvent>,
) {
    while let Some(Ok(msg)) = stream.next().await {
        if let Message::Text(text) = msg {
            if let Ok(phx_msg) = serde_json::from_str::<PhxMessage>(&text) {
                if let Some(event) = parse_event(&phx_msg) {
                    if tx.send(event).is_err() {
                        break;
                    }
                }
            }
        }
    }
}

async fn heartbeat_loop(tx: mpsc::UnboundedSender<Message>) {
    let mut counter: u64 = 10_000;
    loop {
        tokio::time::sleep(tokio::time::Duration::from_secs(30)).await;
        counter += 1;
        let msg = PhxMessage {
            topic: "phoenix".to_string(),
            event: "heartbeat".to_string(),
            payload: serde_json::json!({}),
            msg_ref: Some(counter.to_string()),
            join_ref: None,
        };
        let text = match serde_json::to_string(&msg) {
            Ok(t) => t,
            Err(_) => break,
        };
        if tx.send(Message::Text(text)).is_err() {
            break;
        }
    }
}

fn parse_event(msg: &PhxMessage) -> Option<ChannelEvent> {
    match msg.event.as_str() {
        "doc:state" => {
            let document = msg.payload.get("document")?.as_str()?.to_string();
            let version = msg.payload.get("version")?.as_u64()?;
            let crdt_updates = msg
                .payload
                .get("crdt_updates")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str())
                        .filter_map(|s| BASE64_STANDARD.decode(s).ok())
                        .collect()
                })
                .unwrap_or_default();
            Some(ChannelEvent::DocState {
                document,
                version,
                crdt_updates,
            })
        }
        "doc:change" => {
            let document = msg.payload.get("document")?.as_str()?.to_string();
            let author = msg.payload.get("author")?.as_str()?.to_string();
            let version = msg.payload.get("version")?.as_u64()?;
            Some(ChannelEvent::DocChange {
                document,
                author,
                version,
            })
        }
        "doc:crdt_update" => {
            let update_b64 = msg.payload.get("update")?.as_str()?;
            let update = BASE64_STANDARD.decode(update_b64).ok()?;
            let author = msg.payload.get("author")?.as_str()?.to_string();
            let version = msg.payload.get("version")?.as_u64()?;
            Some(ChannelEvent::CrdtUpdate {
                update,
                author,
                version,
            })
        }
        "doc:patch_broadcast" => {
            let ops_val = msg.payload.get("ops")?;
            let ops: Vec<PatchOp> = serde_json::from_value(ops_val.clone()).ok()?;
            let author = msg.payload.get("author")?.as_str()?.to_string();
            let version = msg.payload.get("version")?.as_u64()?;
            Some(ChannelEvent::DocPatch {
                ops,
                author,
                version,
            })
        }
        "user:joined" => {
            let username = msg.payload.get("username")?.as_str()?.to_string();
            let users = parse_string_array(msg.payload.get("users")?)?;
            Some(ChannelEvent::UserJoined { username, users })
        }
        "user:left" => {
            let username = msg.payload.get("username")?.as_str()?.to_string();
            let users = parse_string_array(msg.payload.get("users")?)?;
            Some(ChannelEvent::UserLeft { username, users })
        }
        "phx_reply" => {
            let status = msg.payload.get("status")?.as_str()?;
            let response = msg.payload.get("response")?;

            if status == "error" {
                return Some(ChannelEvent::Error {
                    reason: response.to_string(),
                });
            }

            if status == "ok" && response.get("version_mismatch").is_some() {
                let document = response.get("document")?.as_str()?.to_string();
                let version = response.get("version")?.as_u64()?;
                return Some(ChannelEvent::PatchRejected { document, version });
            }

            None
        }
        _ => None,
    }
}

fn parse_string_array(val: &Value) -> Option<Vec<String>> {
    val.as_array()
        .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect())
}
