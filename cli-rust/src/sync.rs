use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::sync::Mutex;

use crate::crdt::CrdtDoc;
use crate::phoenix::{ChannelEvent, PhoenixChannel};

/// Run the CRDT sync loop: watch a local file for changes, relay them as CRDT updates,
/// and apply incoming CRDT updates from other users to the local file.
/// Concurrent edits from multiple users are merged automatically.
pub async fn run(
    file_path: PathBuf,
    username: String,
    mut channel: PhoenixChannel,
    mut events: mpsc::UnboundedReceiver<ChannelEvent>,
    use_crdt: bool,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Wait for initial state
    let (initial_doc, initial_text, initial_version) =
        wait_for_initial_state(&mut events).await?;
    let mode_label = if use_crdt { "crdt" } else { "overwrite" };
    eprintln!("[collab] Connected (v{}, mode: {})", initial_version, mode_label);

    // Write initial content to the local file
    tokio::fs::write(&file_path, &initial_text).await?;

    // In CRDT mode, send initial state to establish shared baseline
    if use_crdt {
        let init_state = initial_doc.encode_state();
        let _ = channel.send_crdt_update(&init_state, &initial_text, &username);
    }

    let crdt_doc = Arc::new(Mutex::new(initial_doc));
    let last_content = Arc::new(Mutex::new(initial_text));
    let last_version = Arc::new(Mutex::new(initial_version));
    let skip_next = Arc::new(AtomicBool::new(true));

    // Set up native file watcher
    let (file_tx, mut file_rx) = mpsc::unbounded_channel::<()>();
    let _watcher = setup_file_watcher(&file_path, file_tx)?;

    loop {
        tokio::select! {
            // Local file changed
            Some(()) = file_rx.recv() => {
                if skip_next.load(Ordering::SeqCst) {
                    skip_next.store(false, Ordering::SeqCst);
                    continue;
                }

                // Debounce
                tokio::time::sleep(Duration::from_millis(50)).await;
                while file_rx.try_recv().is_ok() {}

                let content = match tokio::fs::read_to_string(&file_path).await {
                    Ok(c) => c,
                    Err(_) => continue,
                };

                let mut last = last_content.lock().await;
                if content == *last {
                    continue;
                }

                if use_crdt {
                    let doc = crdt_doc.lock().await;
                    let update = doc.apply_local_change(&last, &content);
                    let new_text = doc.get_text();
                    drop(doc);
                    let _ = channel.send_crdt_update(&update, &new_text, &username);
                } else {
                    let _ = channel.send_update(&content, &username);
                }
                *last = content;
            }

            // Server event
            event = events.recv() => {
                match event {
                    Some(ChannelEvent::CrdtUpdate { update, author, version }) => {
                        eprintln!("[collab] CRDT update from {} (v{})", author, version);
                        let doc = crdt_doc.lock().await;
                        match doc.apply_remote_update(&update) {
                            Ok(new_text) => {
                                drop(doc);
                                write_if_changed(&file_path, &new_text, &last_content, &last_version, &skip_next, version).await?;
                            }
                            Err(e) => {
                                eprintln!("[collab] CRDT apply failed: {}", e);
                            }
                        }
                    }
                    Some(ChannelEvent::DocChange { document, author, version }) => {
                        // Non-CRDT update (e.g. from REST API) — reset CRDT doc
                        eprintln!("[collab] Full update from {} (v{})", author, version);
                        let doc = crdt_doc.lock().await;
                        doc.reset_to_text(&document);
                        drop(doc);
                        write_if_changed(&file_path, &document, &last_content, &last_version, &skip_next, version).await?;
                    }
                    Some(ChannelEvent::DocPatch { ops, author, version }) => {
                        // Legacy patch — apply and reset CRDT
                        eprintln!("[collab] Patch from {} (v{})", author, version);
                        let mut last = last_content.lock().await;
                        if let Ok(new_text) = crate::patch::apply_patch(&last, &ops) {
                            let doc = crdt_doc.lock().await;
                            doc.reset_to_text(&new_text);
                            drop(doc);
                            skip_next.store(true, Ordering::SeqCst);
                            tokio::fs::write(&file_path, &new_text).await?;
                            *last = new_text;
                            *last_version.lock().await = version;
                        }
                    }
                    Some(ChannelEvent::PatchRejected { document, version }) => {
                        eprintln!("[collab] Version conflict, resyncing (v{})...", version);
                        let doc = crdt_doc.lock().await;
                        doc.reset_to_text(&document);
                        drop(doc);
                        write_if_changed(&file_path, &document, &last_content, &last_version, &skip_next, version).await?;
                    }
                    Some(ChannelEvent::DocState { document, version, crdt_updates }) => {
                        // Re-sync (e.g. after reconnect)
                        if !crdt_updates.is_empty() {
                            let doc = crdt_doc.lock().await;
                            for u in &crdt_updates {
                                let _ = doc.apply_remote_update(u);
                            }
                            let text = doc.get_text();
                            drop(doc);
                            write_if_changed(&file_path, &text, &last_content, &last_version, &skip_next, version).await?;
                        } else {
                            write_if_changed(&file_path, &document, &last_content, &last_version, &skip_next, version).await?;
                        }
                    }
                    Some(ChannelEvent::UserJoined { username, users }) => {
                        eprintln!("[collab] {} joined (online: {})", username, users.join(", "));
                    }
                    Some(ChannelEvent::UserLeft { username, users }) => {
                        eprintln!("[collab] {} left (online: {})", username, users.join(", "));
                    }
                    Some(ChannelEvent::Error { reason }) => {
                        eprintln!("[collab] Error: {}", reason);
                    }
                    None => break,
                }
            }
        }
    }

    Ok(())
}

async fn wait_for_initial_state(
    events: &mut mpsc::UnboundedReceiver<ChannelEvent>,
) -> Result<(CrdtDoc, String, u64), Box<dyn std::error::Error + Send + Sync>> {
    let timeout = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match events.recv().await {
                Some(ChannelEvent::DocState {
                    document,
                    version,
                    crdt_updates,
                }) => {
                    let (doc, text) = if !crdt_updates.is_empty() {
                        // Initialize from existing CRDT state
                        let doc = CrdtDoc::from_updates(&crdt_updates)
                            .map_err(|e| e.to_string())?;
                        let text = doc.get_text();
                        (doc, text)
                    } else {
                        // First client — create CRDT from plain text
                        let doc = CrdtDoc::from_text(&document);
                        (doc, document)
                    };
                    return Ok((doc, text, version));
                }
                Some(ChannelEvent::Error { reason }) => {
                    return Err(format!("Server error: {}", reason));
                }
                None => {
                    return Err("Connection closed before receiving state".to_string());
                }
                _ => continue,
            }
        }
    });

    match timeout.await {
        Ok(Ok(result)) => Ok(result),
        Ok(Err(e)) => Err(e.into()),
        Err(_) => Err("Timeout waiting for room state".into()),
    }
}

fn setup_file_watcher(
    file_path: &Path,
    file_tx: mpsc::UnboundedSender<()>,
) -> Result<notify::RecommendedWatcher, Box<dyn std::error::Error + Send + Sync>> {
    use notify::{EventKind, RecursiveMode, Watcher};

    let target_name = file_path
        .file_name()
        .ok_or("invalid file path")?
        .to_os_string();
    let watch_dir = file_path
        .parent()
        .unwrap_or(Path::new("."))
        .to_path_buf();

    let mut watcher =
        notify::recommended_watcher(move |res: Result<notify::Event, notify::Error>| {
            if let Ok(event) = res {
                let dominated = matches!(
                    event.kind,
                    EventKind::Modify(_) | EventKind::Create(_)
                );
                if dominated
                    && event
                        .paths
                        .iter()
                        .any(|p| p.file_name() == Some(&target_name))
                {
                    let _ = file_tx.send(());
                }
            }
        })?;

    watcher.watch(&watch_dir, RecursiveMode::NonRecursive)?;
    Ok(watcher)
}

async fn write_if_changed(
    file_path: &Path,
    document: &str,
    last_content: &Arc<Mutex<String>>,
    last_version: &Arc<Mutex<u64>>,
    skip_next: &Arc<AtomicBool>,
    version: u64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut last = last_content.lock().await;
    if document != last.as_str() {
        skip_next.store(true, Ordering::SeqCst);
        tokio::fs::write(file_path, document).await?;
        *last = document.to_string();
    }
    *last_version.lock().await = version;
    Ok(())
}
