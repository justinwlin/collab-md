use clap::{Parser, Subcommand};
use std::path::PathBuf;

mod patch;
mod phoenix;
mod sync;

#[derive(Parser)]
#[command(name = "collab", about = "Live collaborative markdown editing", version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Create a new collaboration room
    Create {
        /// Your display name
        #[arg(long, default_value_t = default_username())]
        name: String,

        /// File to sync
        #[arg(long)]
        file: Option<String>,

        /// Server URL
        #[arg(long, env = "COLLAB_SERVER", default_value = "https://collab-md.fly.dev")]
        server: String,
    },
    /// Join an existing room
    Join {
        /// Room code
        code: String,

        /// Your display name
        #[arg(long, default_value_t = default_username())]
        name: String,

        /// File to sync to
        #[arg(long)]
        file: Option<String>,

        /// Server URL
        #[arg(long, env = "COLLAB_SERVER", default_value = "https://collab-md.fly.dev")]
        server: String,
    },
    /// View version history
    History {
        /// Room code
        code: String,

        /// Server URL
        #[arg(long, env = "COLLAB_SERVER", default_value = "https://collab-md.fly.dev")]
        server: String,
    },
    /// Restore a previous version
    Restore {
        /// Room code
        code: String,
        /// Version number
        version: u64,

        /// Server URL
        #[arg(long, env = "COLLAB_SERVER", default_value = "https://collab-md.fly.dev")]
        server: String,
    },
    /// Show room status
    Status {
        /// Room code
        code: String,

        /// Server URL
        #[arg(long, env = "COLLAB_SERVER", default_value = "https://collab-md.fly.dev")]
        server: String,
    },
    /// Remove collab from your system
    Uninstall,
}

fn default_username() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_else(|_| "anonymous".to_string())
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Create { name, file, server } => cmd_create(&server, &name, file.as_deref()).await,
        Commands::Join {
            code,
            name,
            file,
            server,
        } => cmd_join(&server, &code, &name, file.as_deref()).await,
        Commands::History { code, server } => cmd_history(&server, &code).await,
        Commands::Restore {
            code,
            version,
            server,
        } => cmd_restore(&server, &code, version).await,
        Commands::Status { code, server } => cmd_status(&server, &code).await,
        Commands::Uninstall => cmd_uninstall().await,
    };

    if let Err(e) = result {
        eprintln!("Error: {}", e);
        std::process::exit(1);
    }
}

async fn cmd_create(
    server: &str,
    name: &str,
    file: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{}/api/rooms", server))
        .send()
        .await?;

    if resp.status() != 201 {
        return Err(format!("Failed to create room: HTTP {}", resp.status()).into());
    }

    let body: serde_json::Value = resp.json().await?;
    let code = body["code"]
        .as_str()
        .ok_or("Invalid response: missing code")?;

    eprintln!("Room created: {}", code);
    eprintln!("Share this code: collab join {} --name <name>", code);
    eprintln!();

    // Seed room with existing file content
    if let Some(path) = file {
        if std::path::Path::new(path).exists() {
            if let Ok(content) = tokio::fs::read_to_string(path).await {
                if !content.is_empty() {
                    eprintln!("[collab] Uploading existing file to room...");
                    client
                        .put(format!("{}/api/rooms/{}/document", server, code))
                        .json(&serde_json::json!({
                            "document": content,
                            "author": name,
                        }))
                        .send()
                        .await?;
                }
            }
        }
    }

    cmd_join(server, code, name, file).await
}

async fn cmd_join(
    server: &str,
    code: &str,
    name: &str,
    file: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let file_path = match file {
        Some(f) => PathBuf::from(f),
        None => PathBuf::from(format!("collab-{}.md", code)),
    };
    let file_path = if file_path.is_absolute() {
        file_path
    } else {
        std::env::current_dir()?.join(file_path)
    };

    eprintln!("Joining room {} as {}...", code, name);
    eprintln!("Syncing to: {}", file_path.display());
    eprintln!("Edit the file with any editor. Changes sync automatically.");
    eprintln!("Press Ctrl+C to leave.");
    eprintln!();

    let topic = format!("room:{}", code);
    let (channel, events) = phoenix::PhoenixChannel::connect(server, name, &topic).await?;

    sync::run(file_path, name.to_string(), channel, events)
        .await
        .map_err(|e| -> Box<dyn std::error::Error> { e.to_string().into() })?;

    Ok(())
}

async fn cmd_history(server: &str, code: &str) -> Result<(), Box<dyn std::error::Error>> {
    let resp = reqwest::get(format!("{}/api/rooms/{}/versions", server, code)).await?;

    match resp.status().as_u16() {
        200 => {
            let body: serde_json::Value = resp.json().await?;
            let versions = body["versions"]
                .as_array()
                .ok_or("Invalid response")?;
            if versions.is_empty() {
                println!("No versions yet.");
            } else {
                println!("Version history for room {}:\n", code);
                for v in versions {
                    println!(
                        "  v{}  by {}  at {}",
                        v["number"], v["author"], v["timestamp"]
                    );
                }
            }
        }
        404 => println!("Room {} not found.", code),
        s => println!("Error: HTTP {}", s),
    }

    Ok(())
}

async fn cmd_restore(
    server: &str,
    code: &str,
    version: u64,
) -> Result<(), Box<dyn std::error::Error>> {
    let client = reqwest::Client::new();
    let resp = client
        .put(format!("{}/api/rooms/{}/restore/{}", server, code, version))
        .send()
        .await?;

    match resp.status().as_u16() {
        200 => {
            let body: serde_json::Value = resp.json().await?;
            println!("Restored to version {}. Document:\n", version);
            println!("{}", body["document"].as_str().unwrap_or(""));
        }
        404 => println!("Room or version not found."),
        s => println!("Error: HTTP {}", s),
    }

    Ok(())
}

async fn cmd_uninstall() -> Result<(), Box<dyn std::error::Error>> {
    let exe = std::env::current_exe()?;
    eprintln!("Removing {}...", exe.display());
    std::fs::remove_file(&exe)?;
    eprintln!("collab has been uninstalled.");
    Ok(())
}

async fn cmd_status(server: &str, code: &str) -> Result<(), Box<dyn std::error::Error>> {
    let resp = reqwest::get(format!("{}/api/rooms/{}/status", server, code)).await?;

    match resp.status().as_u16() {
        200 => {
            let body: serde_json::Value = resp.json().await?;
            println!("Room: {}", code);
            println!("Version: {}", body["version"]);
            let users = body["users"]
                .as_array()
                .map(|u| {
                    u.iter()
                        .filter_map(|v| v.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            println!("Online: {}", users);
        }
        404 => println!("Room {} not found.", code),
        s => println!("Error: HTTP {}", s),
    }

    Ok(())
}
