use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::sync::Mutex;

use crate::patch::{apply_patch, compute_patch, PatchOp};
use crate::phoenix::{ChannelEvent, PhoenixChannel};

/// Run the sync loop: watch a local file for changes and relay them to the server,
/// and apply incoming changes from other users to the local file.
pub async fn run(
    file_path: PathBuf,
    username: String,
    mut channel: PhoenixChannel,
    mut events: mpsc::UnboundedReceiver<ChannelEvent>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Wait for initial document state from the server
    let (initial_content, initial_version) = wait_for_initial_state(&mut events).await?;
    eprintln!("[collab] Connected (v{})", initial_version);

    // Write initial content to the local file
    tokio::fs::write(&file_path, &initial_content).await?;

    let last_content = Arc::new(Mutex::new(initial_content));
    let last_version = Arc::new(Mutex::new(initial_version));
    let skip_next = Arc::new(AtomicBool::new(true)); // skip the write we just did

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

                // Debounce: wait briefly and drain extra events
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

                let ops = compute_patch(&last, &content);
                if ops.is_empty() {
                    continue;
                }

                let version = *last_version.lock().await;

                if channel.send_patch(&ops, &username, version).is_err() {
                    // Fallback to full document update
                    let _ = channel.send_update(&content, &username);
                }

                *last = content;
            }

            // Server event
            event = events.recv() => {
                match event {
                    Some(ChannelEvent::DocChange { document, author, version }) => {
                        eprintln!("[collab] Update from {} (v{})", author, version);
                        write_if_changed(&file_path, &document, &last_content, &last_version, &skip_next, version).await?;
                    }
                    Some(ChannelEvent::DocPatch { ops, author, version }) => {
                        eprintln!("[collab] Patch from {} (v{})", author, version);
                        apply_remote_patch(&file_path, &ops, &last_content, &last_version, &skip_next, version).await?;
                    }
                    Some(ChannelEvent::PatchRejected { document, version }) => {
                        eprintln!("[collab] Version conflict, resyncing (v{})...", version);
                        write_if_changed(&file_path, &document, &last_content, &last_version, &skip_next, version).await?;
                    }
                    Some(ChannelEvent::DocState { document, version }) => {
                        write_if_changed(&file_path, &document, &last_content, &last_version, &skip_next, version).await?;
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
) -> Result<(String, u64), Box<dyn std::error::Error + Send + Sync>> {
    let timeout = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match events.recv().await {
                Some(ChannelEvent::DocState { document, version }) => {
                    return Ok((document, version));
                }
                Some(ChannelEvent::Error { reason }) => {
                    return Err(format!("Server error: {}", reason));
                }
                None => {
                    return Err("Connection closed before receiving state".to_string());
                }
                _ => continue, // skip user:joined etc until we get state
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

async fn apply_remote_patch(
    file_path: &Path,
    ops: &[PatchOp],
    last_content: &Arc<Mutex<String>>,
    last_version: &Arc<Mutex<u64>>,
    skip_next: &Arc<AtomicBool>,
    version: u64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut last = last_content.lock().await;
    match apply_patch(&last, ops) {
        Ok(new_content) => {
            skip_next.store(true, Ordering::SeqCst);
            tokio::fs::write(file_path, &new_content).await?;
            *last = new_content;
            *last_version.lock().await = version;
        }
        Err(e) => {
            eprintln!(
                "[collab] Failed to apply patch: {}. Waiting for full sync.",
                e
            );
        }
    }
    Ok(())
}
