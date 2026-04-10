//! End-to-end integration tests for the collab CLI.
//!
//! These tests require a running Phoenix server.
//! Default: http://localhost:4000 (override with COLLAB_TEST_SERVER env var).
//!
//! Run with: ./test_e2e.sh (starts server automatically)
//! Or manually: cargo test --test e2e -- --nocapture

use base64::prelude::*;
use collab::crdt::CrdtDoc;
use collab::patch::{apply_patch, compute_patch};
use collab::phoenix::{ChannelEvent, PhoenixChannel};
use reqwest::Client;
use serde_json::Value;
use std::time::Duration;
use tokio::sync::mpsc;

fn server_url() -> String {
    std::env::var("COLLAB_TEST_SERVER").unwrap_or_else(|_| "http://localhost:4000".to_string())
}

async fn create_room(client: &Client) -> String {
    let resp = client
        .post(format!("{}/api/rooms", server_url()))
        .send()
        .await
        .expect("create room request failed");
    assert_eq!(resp.status(), 201, "Expected 201 from room creation");
    let body: Value = resp.json().await.expect("parse room response");
    body["code"]
        .as_str()
        .expect("code in response")
        .to_string()
}

async fn seed_document(client: &Client, code: &str, content: &str) {
    let resp = client
        .put(format!("{}/api/rooms/{}/document", server_url(), code))
        .json(&serde_json::json!({
            "document": content,
            "author": "test-setup",
        }))
        .send()
        .await
        .expect("seed document failed");
    assert!(
        resp.status().is_success(),
        "Seed document returned {}",
        resp.status()
    );
}

async fn connect_user(
    code: &str,
    username: &str,
) -> (PhoenixChannel, mpsc::UnboundedReceiver<ChannelEvent>) {
    let topic = format!("room:{}", code);
    PhoenixChannel::connect(&server_url(), username, &topic)
        .await
        .unwrap_or_else(|e| panic!("Failed to connect as {}: {}", username, e))
}

async fn wait_for_doc_state(
    events: &mut mpsc::UnboundedReceiver<ChannelEvent>,
) -> (String, u64, Vec<Vec<u8>>) {
    let timeout = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match events.recv().await {
                Some(ChannelEvent::DocState {
                    document,
                    version,
                    crdt_updates,
                }) => {
                    return (document, version, crdt_updates);
                }
                Some(_) => continue,
                None => panic!("Channel closed while waiting for doc:state"),
            }
        }
    });
    timeout.await.expect("Timeout waiting for doc:state")
}

fn drain_events(events: &mut mpsc::UnboundedReceiver<ChannelEvent>) {
    while events.try_recv().is_ok() {}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_create_room() {
    let client = Client::new();
    let code = create_room(&client).await;
    assert!(!code.is_empty(), "Room code should not be empty");
    assert_eq!(code.len(), 6, "Room codes are 6 characters");
}

#[tokio::test]
async fn test_seed_and_fetch_document() {
    let client = Client::new();
    let code = create_room(&client).await;

    seed_document(&client, &code, "# Hello\nWorld\n").await;

    let resp = reqwest::get(format!("{}/api/rooms/{}/document", server_url(), &code))
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["document"].as_str().unwrap(), "# Hello\nWorld\n");
}

#[tokio::test]
async fn test_websocket_join_receives_state() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "initial content\n").await;

    let (_channel, mut events) = connect_user(&code, "alice").await;
    let (doc, version, _) = wait_for_doc_state(&mut events).await;

    assert_eq!(doc, "initial content\n");
    assert!(version > 0);
}

#[tokio::test]
async fn test_full_doc_sync_between_two_users() {
    let client = Client::new();
    let code = create_room(&client).await;

    // Alice joins
    let (mut alice_ch, mut alice_events) = connect_user(&code, "alice").await;
    wait_for_doc_state(&mut alice_events).await;

    // Bob joins
    let (_bob_ch, mut bob_events) = connect_user(&code, "bob").await;
    wait_for_doc_state(&mut bob_events).await;

    // Give user:joined events time to propagate, then drain
    tokio::time::sleep(Duration::from_millis(200)).await;
    drain_events(&mut alice_events);
    drain_events(&mut bob_events);

    // Alice sends a full document update
    alice_ch
        .send_update("# Hello from Alice\n", "alice")
        .unwrap();

    // Bob should receive the change
    let event = tokio::time::timeout(Duration::from_secs(5), bob_events.recv())
        .await
        .expect("Timeout waiting for bob's doc:change")
        .expect("Channel closed");

    match event {
        ChannelEvent::DocChange {
            document, author, ..
        } => {
            assert_eq!(document, "# Hello from Alice\n");
            assert_eq!(author, "alice");
        }
        other => panic!("Expected DocChange, got {:?}", other),
    }
}

#[tokio::test]
async fn test_patch_sync_between_two_users() {
    let client = Client::new();
    let code = create_room(&client).await;
    let initial = "line 1\nline 2\nline 3\n";
    seed_document(&client, &code, initial).await;

    // Alice joins
    let (mut alice_ch, mut alice_events) = connect_user(&code, "alice").await;
    let (_, alice_version, _) = wait_for_doc_state(&mut alice_events).await;

    // Bob joins
    let (_bob_ch, mut bob_events) = connect_user(&code, "bob").await;
    wait_for_doc_state(&mut bob_events).await;

    tokio::time::sleep(Duration::from_millis(200)).await;
    drain_events(&mut alice_events);
    drain_events(&mut bob_events);

    // Alice computes and sends a patch
    let new_content = "line 1\nmodified line 2\nline 3\nnew line 4\n";
    let ops = compute_patch(initial, new_content);
    assert!(!ops.is_empty(), "Patch should not be empty");

    alice_ch
        .send_patch(&ops, "alice", alice_version)
        .unwrap();

    // Bob should receive the patch broadcast
    let event = tokio::time::timeout(Duration::from_secs(5), bob_events.recv())
        .await
        .expect("Timeout waiting for bob's doc:patch_broadcast")
        .expect("Channel closed");

    match event {
        ChannelEvent::DocPatch {
            ops: recv_ops,
            author,
            ..
        } => {
            assert_eq!(author, "alice");
            let result = apply_patch(initial, &recv_ops).unwrap();
            assert_eq!(result, new_content);
        }
        other => panic!("Expected DocPatch, got {:?}", other),
    }

    // Verify server document is also updated
    let resp = reqwest::get(format!(
        "{}/api/rooms/{}/document",
        server_url(),
        &code
    ))
    .await
    .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["document"].as_str().unwrap(), new_content);
}

#[tokio::test]
async fn test_patch_version_mismatch_returns_full_state() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "original\n").await;

    let (mut alice_ch, mut alice_events) = connect_user(&code, "alice").await;
    let (_, alice_version, _) = wait_for_doc_state(&mut alice_events).await;

    // Advance the version via REST so Alice's base_version becomes stale
    seed_document(&client, &code, "updated by someone else\n").await;

    tokio::time::sleep(Duration::from_millis(100)).await;
    drain_events(&mut alice_events);

    // Alice sends patch with stale base_version
    let ops = compute_patch("original\n", "original\nplus more\n");
    alice_ch
        .send_patch(&ops, "alice", alice_version)
        .unwrap();

    // Should receive PatchRejected with current state
    let event = tokio::time::timeout(Duration::from_secs(5), alice_events.recv())
        .await
        .expect("Timeout waiting for patch rejection")
        .expect("Channel closed");

    match event {
        ChannelEvent::PatchRejected {
            document, version, ..
        } => {
            assert_eq!(document, "updated by someone else\n");
            assert!(version > alice_version);
        }
        other => panic!("Expected PatchRejected, got {:?}", other),
    }
}

#[tokio::test]
async fn test_multiple_sequential_patches() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "v0\n").await;

    let (mut alice_ch, mut alice_events) = connect_user(&code, "alice").await;
    let (_, mut version, _) = wait_for_doc_state(&mut alice_events).await;

    let (_bob_ch, mut bob_events) = connect_user(&code, "bob").await;
    wait_for_doc_state(&mut bob_events).await;

    tokio::time::sleep(Duration::from_millis(200)).await;
    drain_events(&mut alice_events);
    drain_events(&mut bob_events);

    // Send multiple patches in sequence
    let mut current = "v0\n".to_string();
    let edits = vec![
        "v0\nline A\n",
        "v0\nline A\nline B\n",
        "v0\nline A\nline B\nline C\n",
    ];

    for edit in &edits {
        let ops = compute_patch(&current, edit);
        alice_ch.send_patch(&ops, "alice", version).unwrap();

        // Wait for bob to receive
        let event = tokio::time::timeout(Duration::from_secs(5), bob_events.recv())
            .await
            .expect("Timeout")
            .expect("Closed");

        match event {
            ChannelEvent::DocPatch {
                ops: recv_ops,
                version: new_version,
                ..
            } => {
                current = apply_patch(&current, &recv_ops).unwrap();
                assert_eq!(current, *edit);
                version = new_version;
            }
            other => panic!("Expected DocPatch, got {:?}", other),
        }
    }

    assert_eq!(current, "v0\nline A\nline B\nline C\n");
}

// ---------------------------------------------------------------------------
// CLI command tests (history, restore, status)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_history_shows_versions() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "v1 content").await;
    seed_document(&client, &code, "v2 content").await;

    let resp = client
        .get(format!("{}/api/rooms/{}/versions", server_url(), &code))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let body: Value = resp.json().await.unwrap();
    let versions = body["versions"].as_array().unwrap();
    assert_eq!(versions.len(), 2);
    // Newest first
    assert_eq!(versions[0]["number"].as_u64().unwrap(), 2);
    assert_eq!(versions[1]["number"].as_u64().unwrap(), 1);
    assert_eq!(versions[0]["author"].as_str().unwrap(), "test-setup");
}

#[tokio::test]
async fn test_history_empty_room() {
    let client = Client::new();
    let code = create_room(&client).await;

    let resp = client
        .get(format!("{}/api/rooms/{}/versions", server_url(), &code))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let body: Value = resp.json().await.unwrap();
    let versions = body["versions"].as_array().unwrap();
    assert!(versions.is_empty());
}

#[tokio::test]
async fn test_restore_version() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "original").await;
    seed_document(&client, &code, "changed").await;

    let resp = client
        .put(format!("{}/api/rooms/{}/restore/1", server_url(), &code))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["document"].as_str().unwrap(), "original");

    // Verify the document was actually restored
    let resp = client
        .get(format!("{}/api/rooms/{}/document", server_url(), &code))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["document"].as_str().unwrap(), "original");
}

#[tokio::test]
async fn test_restore_nonexistent_version() {
    let client = Client::new();
    let code = create_room(&client).await;

    let resp = client
        .put(format!("{}/api/rooms/{}/restore/999", server_url(), &code))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
}

#[tokio::test]
async fn test_status_shows_room_info() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "content").await;

    let resp = client
        .get(format!("{}/api/rooms/{}/status", server_url(), &code))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let body: Value = resp.json().await.unwrap();
    assert_eq!(body["version"].as_u64().unwrap(), 1);
    assert!(body["users"].as_array().unwrap().is_empty());
    assert!(body["created_at"].as_str().is_some());
}

#[tokio::test]
async fn test_status_shows_connected_users() {
    let client = Client::new();
    let code = create_room(&client).await;

    // Connect a user via WebSocket
    let (_ch, mut events) = connect_user(&code, "alice").await;
    wait_for_doc_state(&mut events).await;

    // Give the join time to register
    tokio::time::sleep(Duration::from_millis(100)).await;

    let resp = client
        .get(format!("{}/api/rooms/{}/status", server_url(), &code))
        .send()
        .await
        .unwrap();
    let body: Value = resp.json().await.unwrap();
    let users: Vec<&str> = body["users"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| v.as_str())
        .collect();
    assert!(users.contains(&"alice"));
}

#[tokio::test]
async fn test_status_nonexistent_room() {
    let client = Client::new();
    let resp = client
        .get(format!("{}/api/rooms/nope00/status", server_url()))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 404);
}

// ---------------------------------------------------------------------------
// Sync engine integration test
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_sync_engine_local_edit_propagates() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "initial\n").await;

    // Start sync engine on a temp file
    let tmp_dir = std::env::temp_dir().join(format!("collab_test_{}", code));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let file_path = tmp_dir.join("test.md");

    let topic = format!("room:{}", code);
    let (channel, events) =
        PhoenixChannel::connect(&server_url(), "sync-tester", &topic)
            .await
            .unwrap();

    let fp = file_path.clone();
    let sync_handle = tokio::spawn(async move {
        collab::sync::run(fp, "sync-tester".to_string(), channel, events, true).await
    });

    // Wait for sync to write initial file
    tokio::time::sleep(Duration::from_millis(500)).await;
    let content = tokio::fs::read_to_string(&file_path).await.unwrap();
    assert_eq!(content, "initial\n", "Sync should write initial content to file");

    // Edit the local file
    tokio::fs::write(&file_path, "initial\nedited locally\n").await.unwrap();

    // Poll server until the change propagates (CI runners can be slow)
    let expected = "initial\nedited locally\n";
    let mut propagated = false;
    for _ in 0..20 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let resp = client
            .get(format!("{}/api/rooms/{}/document", server_url(), &code))
            .send()
            .await
            .unwrap();
        let body: Value = resp.json().await.unwrap();
        if body["document"].as_str().unwrap_or("") == expected {
            propagated = true;
            break;
        }
    }
    assert!(propagated, "Local edit should propagate to server within 10s");

    sync_handle.abort();
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

#[tokio::test]
async fn test_sync_engine_remote_edit_updates_file() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "initial\n").await;

    let tmp_dir = std::env::temp_dir().join(format!("collab_test_remote_{}", code));
    std::fs::create_dir_all(&tmp_dir).unwrap();
    let file_path = tmp_dir.join("test.md");

    let topic = format!("room:{}", code);
    let (channel, events) =
        PhoenixChannel::connect(&server_url(), "sync-tester", &topic)
            .await
            .unwrap();

    let fp = file_path.clone();
    let sync_handle = tokio::spawn(async move {
        collab::sync::run(fp, "sync-tester".to_string(), channel, events, true).await
    });

    // Wait for initial sync
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Update document via REST (simulates another user editing)
    client
        .put(format!("{}/api/rooms/{}/document", server_url(), &code))
        .json(&serde_json::json!({
            "document": "initial\nremote edit\n",
            "author": "remote-user",
        }))
        .send()
        .await
        .unwrap();

    // Poll file until the remote edit lands (CI runners can be slow)
    let expected = "initial\nremote edit\n";
    let mut received = false;
    for _ in 0..20 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        if let Ok(content) = tokio::fs::read_to_string(&file_path).await {
            if content == expected {
                received = true;
                break;
            }
        }
    }
    assert!(received, "Remote edit should be written to local file within 10s");

    sync_handle.abort();
    let _ = std::fs::remove_dir_all(&tmp_dir);
}

// ---------------------------------------------------------------------------
// CRDT sync tests
// ---------------------------------------------------------------------------

#[tokio::test]
async fn test_crdt_update_syncs_between_users() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "hello world").await;

    // Alice joins and establishes CRDT baseline
    let (mut alice_ch, mut alice_events) = connect_user(&code, "alice").await;
    wait_for_doc_state(&mut alice_events).await;

    let alice_doc = CrdtDoc::from_text("hello world");
    let init_state = alice_doc.encode_state();
    alice_ch
        .send_crdt_update(&init_state, "hello world", "alice")
        .unwrap();

    tokio::time::sleep(Duration::from_millis(200)).await;
    drain_events(&mut alice_events);

    // Bob joins — should receive CRDT state
    let (_bob_ch, mut bob_events) = connect_user(&code, "bob").await;
    let (_, _, bob_crdt_updates) = wait_for_doc_state(&mut bob_events).await;
    assert!(
        !bob_crdt_updates.is_empty(),
        "Bob should receive CRDT state"
    );

    // Bob initializes from CRDT state
    let bob_doc = CrdtDoc::from_updates(&bob_crdt_updates).unwrap();
    assert_eq!(bob_doc.get_text(), "hello world");

    tokio::time::sleep(Duration::from_millis(200)).await;
    drain_events(&mut alice_events);
    drain_events(&mut bob_events);

    // Alice makes a CRDT edit
    let update = alice_doc.apply_local_change("hello world", "hello beautiful world");
    alice_ch
        .send_crdt_update(&update, &alice_doc.get_text(), "alice")
        .unwrap();

    // Bob should receive the CRDT update
    let event = tokio::time::timeout(Duration::from_secs(5), bob_events.recv())
        .await
        .expect("Timeout")
        .expect("Closed");

    match event {
        ChannelEvent::CrdtUpdate {
            update: recv_update,
            author,
            ..
        } => {
            assert_eq!(author, "alice");
            let result = bob_doc.apply_remote_update(&recv_update).unwrap();
            assert_eq!(result, "hello beautiful world");
        }
        other => panic!("Expected CrdtUpdate, got {:?}", other),
    }
}

#[tokio::test]
async fn test_crdt_concurrent_edits_merge() {
    let client = Client::new();
    let code = create_room(&client).await;
    seed_document(&client, &code, "hello world").await;

    // Alice joins and establishes CRDT baseline
    let (mut alice_ch, mut alice_events) = connect_user(&code, "alice").await;
    wait_for_doc_state(&mut alice_events).await;

    let origin_doc = CrdtDoc::from_text("hello world");
    let init_state = origin_doc.encode_state();
    alice_ch
        .send_crdt_update(&init_state, "hello world", "alice")
        .unwrap();

    tokio::time::sleep(Duration::from_millis(300)).await;
    drain_events(&mut alice_events);

    // Bob joins and gets CRDT state
    let (mut bob_ch, mut bob_events) = connect_user(&code, "bob").await;
    let (_, _, bob_crdt_updates) = wait_for_doc_state(&mut bob_events).await;

    // Both create docs from the shared CRDT state
    let alice_doc = CrdtDoc::from_updates(&bob_crdt_updates).unwrap();
    let bob_doc = CrdtDoc::from_updates(&bob_crdt_updates).unwrap();

    tokio::time::sleep(Duration::from_millis(200)).await;
    drain_events(&mut alice_events);
    drain_events(&mut bob_events);

    // Alice: "hello world" -> "hello beautiful world"
    let alice_update = alice_doc.apply_local_change("hello world", "hello beautiful world");
    alice_ch
        .send_crdt_update(&alice_update, &alice_doc.get_text(), "alice")
        .unwrap();

    // Bob: "hello world" -> "hello world!" (concurrent)
    let bob_update = bob_doc.apply_local_change("hello world", "hello world!");
    bob_ch
        .send_crdt_update(&bob_update, &bob_doc.get_text(), "bob")
        .unwrap();

    // Wait for both updates to propagate
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Collect and apply received updates
    while let Ok(event) = alice_events.try_recv() {
        if let ChannelEvent::CrdtUpdate { update, .. } = event {
            let _ = alice_doc.apply_remote_update(&update);
        }
    }
    while let Ok(event) = bob_events.try_recv() {
        if let ChannelEvent::CrdtUpdate { update, .. } = event {
            let _ = bob_doc.apply_remote_update(&update);
        }
    }

    // Both must converge with both edits present
    let alice_text = alice_doc.get_text();
    let bob_text = bob_doc.get_text();
    assert_eq!(
        alice_text, bob_text,
        "CRDT docs must converge after concurrent edits"
    );
    assert!(alice_text.contains("beautiful"), "Should contain Alice's edit: {}", alice_text);
    assert!(alice_text.contains("!"), "Should contain Bob's edit: {}", alice_text);
}

#[tokio::test]
async fn test_crdt_state_persists_for_new_joiners() {
    let client = Client::new();
    let code = create_room(&client).await;

    // Alice joins, creates CRDT, makes multiple edits
    let (mut alice_ch, mut alice_events) = connect_user(&code, "alice").await;
    wait_for_doc_state(&mut alice_events).await;

    let alice_doc = CrdtDoc::from_text("");
    let update1 = alice_doc.apply_local_change("", "line 1\n");
    alice_ch
        .send_crdt_update(&update1, &alice_doc.get_text(), "alice")
        .unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;

    let update2 = alice_doc.apply_local_change("line 1\n", "line 1\nline 2\n");
    alice_ch
        .send_crdt_update(&update2, &alice_doc.get_text(), "alice")
        .unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Bob joins late — should get accumulated CRDT state
    let (_bob_ch, mut bob_events) = connect_user(&code, "bob").await;
    let (doc_text, _, crdt_updates) = wait_for_doc_state(&mut bob_events).await;

    assert_eq!(doc_text, "line 1\nline 2\n");
    assert!(!crdt_updates.is_empty(), "Should have CRDT updates");

    let bob_doc = CrdtDoc::from_updates(&crdt_updates).unwrap();
    assert_eq!(bob_doc.get_text(), "line 1\nline 2\n");
}
