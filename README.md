# CollabMd

Real-time collaborative markdown editing from any editor. Create a room, share the code, and edit together — changes sync instantly via diff patches over WebSockets.

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
cargo install --path .
```

### Use It

```sh
# Create a room
collab create --name alice

# Share the code with someone else
collab join abc123 --name bob

# Sync an existing file
collab create --name alice --file notes.md

# View version history
collab history abc123

# Restore a previous version
collab restore abc123 2

# Check who's online
collab status abc123

# Uninstall
collab uninstall
```

Edit the synced file with any editor (VS Code, vim, nano, etc). Changes propagate instantly to all connected users.

## Default Server

The CLI points to the public server at `https://collab-md.fly.dev` by default. This is free to use for quick collaboration sessions.

Rooms are ephemeral — they auto-delete after 4 hours of inactivity (or 30 minutes after the last person leaves). There is no persistence or authentication.

To use a different server, pass `--server` or set the environment variable:

```sh
# Per-command
collab create --name alice --server https://your-server.com

# Or set globally
export COLLAB_SERVER=https://your-server.com
collab create --name alice
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

1. **File watchers** (FSEvents on macOS, inotify on Linux) detect local edits instantly
2. **Line-based diffs** are computed and sent as patches over WebSocket
3. The server applies the patch, increments the version, and broadcasts to other clients
4. If two users edit at the same time and versions conflict, the server rejects the stale patch and sends the current document for resync
5. Every edit creates a version snapshot that can be viewed or restored

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
collab uninstall
```

Or manually: `rm ~/.local/bin/collab`
