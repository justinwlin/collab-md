# CollabMd

Real-time collaborative markdown editing from any editor. Create a room, share the code, and edit together — concurrent edits merge automatically via CRDT.

## Quick Start

### Install the CLI

```sh
curl -sSL https://raw.githubusercontent.com/justinwlin/collab-md/main/install.sh | sh
```

No dependencies needed — downloads a single static binary for your platform.

Or build from source (requires [Rust](https://rustup.rs)):

```sh
git clone https://github.com/justinwlin/collab-md.git
cd collab-md/cli-rust
cargo install --path . --bin collabmd
```

### Use It

```sh
# Create a room
collabmd create --name alice

# Share the code with someone else
collabmd join abc123 --name bob

# Sync an existing file
collabmd create --name alice --file notes.md

# View version history
collabmd history abc123

# Restore a previous version
collabmd restore abc123 2

# Check who's online
collabmd status abc123

# Uninstall
collabmd uninstall
```

Edit the synced file with any editor (VS Code, vim, nano, etc). Changes propagate instantly to all connected users.

### Sync Modes

```sh
# Default: CRDT auto-merge — concurrent edits from multiple users merge automatically
collabmd join abc123 --name alice --mode crdt

# Overwrite mode — last save wins (simpler, no merging)
collabmd join abc123 --name alice --mode overwrite
```

Both modes create version snapshots on every edit. Use `collabmd history` and `collabmd restore` to roll back.

## Default Server

The CLI connects to **`https://collab-md.fly.dev`** by default. This is a free public server for quick collaboration sessions.

### What you should know

- **No authentication** — anyone with a room code can join and edit. Room codes are random 6-character hex strings (16 million possibilities), so they're not guessable, but treat them like a shared link.
- **No persistence** — rooms auto-delete after 4 hours of inactivity (or 30 minutes after the last person leaves). Nothing is stored permanently.
- **No encryption** — content is transmitted over TLS (HTTPS/WSS) but the server can see room contents in memory. Don't use it for secrets or sensitive data.
- **Resource limits** — the server runs on a 256MB Fly.io instance with a 1000 connection limit. It's meant for small-team collaboration, not heavy production use.
- **Content is ephemeral** — there's no logging, no database, no disk storage. When a room closes, the content is gone.

### For private or sensitive work, self-host

If you need privacy, authentication, or higher limits, self-host your own server (see below) and point the CLI at it:

```sh
# Per-command
collabmd create --name alice --server https://your-server.com

# Or set globally
export COLLAB_SERVER=https://your-server.com
```

## Self-Hosting

### Option 1: Docker (recommended)

```sh
# Generate a secret key
SECRET=$(openssl rand -hex 64)

# Build and run
docker build -t collab-md .
docker run -d \
  -e SECRET_KEY_BASE="$SECRET" \
  -e PHX_HOST=your-domain.com \
  -p 4000:4000 \
  collab-md
```

Your server is now at `http://your-domain.com:4000`. Point the CLI at it:

```sh
export COLLAB_SERVER=http://your-domain.com:4000
```

### Option 2: Deploy to Fly.io

```sh
# Install flyctl: https://fly.io/docs/flyctl/install/
fly launch
fly secrets set SECRET_KEY_BASE=$(openssl rand -hex 64)
fly deploy
```

The included `fly.toml` is pre-configured. Your server will be at `https://your-app-name.fly.dev`.

### Option 3: Run from source

Requires [Elixir](https://elixir-lang.org/install.html) 1.15+.

```sh
git clone https://github.com/justinwlin/collab-md.git
cd collab-md
mix deps.get

# Development
mix phx.server

# Production release
MIX_ENV=prod mix release
SECRET_KEY_BASE=$(openssl rand -hex 64) PHX_HOST=your-domain.com PORT=4000 _build/prod/rel/collab_md/bin/server
```

### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | **Yes** (prod) | — | 64+ char secret for signing cookies. Generate with `openssl rand -hex 64` |
| `PHX_HOST` | No | `example.com` | Your server's domain name |
| `PORT` | No | `4000` | HTTP listen port |
| `DNS_CLUSTER_QUERY` | No | — | For multi-node clustering (advanced) |

### REST API

The server exposes a REST API for programmatic access:

```sh
# Create a room
curl -X POST https://your-server.com/api/rooms

# Get document
curl https://your-server.com/api/rooms/CODE/document

# Update document
curl -X PUT https://your-server.com/api/rooms/CODE/document \
  -H 'Content-Type: application/json' \
  -d '{"document": "# Hello", "author": "script"}'

# Version history
curl https://your-server.com/api/rooms/CODE/versions

# Restore a version
curl -X PUT https://your-server.com/api/rooms/CODE/restore/1

# Room status
curl https://your-server.com/api/rooms/CODE/status
```

## How It Works

1. **File watchers** (FSEvents on macOS, inotify on Linux) detect local edits instantly — no polling
2. **CRDT sync** (Yjs) — edits are encoded as CRDT operations and sent over WebSocket. Concurrent edits from multiple users merge automatically without conflicts
3. The server is a **thin relay** — it stores and broadcasts binary CRDT updates without needing to understand them. Plain text is maintained alongside for the REST API
4. Every edit creates a **version snapshot** that can be viewed with `collabmd history` or rolled back with `collabmd restore`
5. **Overwrite mode** (`--mode overwrite`) is available as an alternative — sends the full document on each save, last write wins

## Development

```sh
# Start the server
mix phx.server

# Run Elixir tests
mix test

# Run Rust unit tests
cd cli-rust && cargo test --lib

# Run full E2E suite (starts server automatically)
./test_e2e.sh
```

## Uninstall

```sh
collabmd uninstall
```

Or manually: `rm ~/.local/bin/collabmd`
