# CollabMd

Real-time collaborative markdown editing. Humans edit in the browser or any editor, AI agents edit via API — concurrent edits merge automatically via CRDT.

## Three Ways In

| Who | How | Entry point |
|---|---|---|
| Human (browser) | Open the web editor | `https://collab-md.fly.dev/rooms/CODE` |
| Human (terminal) | CLI syncs a local file | `collabmd join CODE --name alice` |
| AI agent (Claude, etc) | REST API | `curl -X PUT .../api/rooms/CODE/document` |

All three share the same room. Edits from any source merge in real-time.

## Quick Start

### Browser

1. Create a room: `curl -X POST https://collab-md.fly.dev/api/rooms`
2. Open `https://collab-md.fly.dev/rooms/CODE` in your browser
3. Share the URL — anyone with it can edit

### CLI

```sh
# Install (one line, no dependencies)
curl -sSL https://raw.githubusercontent.com/justinwlin/collab-md/main/install.sh | sh

# Create a room
collabmd create --name alice

# Join from another machine
collabmd join abc123 --name bob

# Sync an existing file
collabmd create --name alice --file notes.md
```

Edit the synced file with any editor (VS Code, vim, nano, etc). Changes propagate instantly.

### AI Agents (Claude Code, scripts, etc)

Give your agent context by running `!collabmd --help` in your session, then use the API:

```sh
# Create a room
curl -X POST https://collab-md.fly.dev/api/rooms

# Read the document
curl https://collab-md.fly.dev/api/rooms/CODE/document

# Write to the document
curl -X PUT https://collab-md.fly.dev/api/rooms/CODE/document \
  -H 'Content-Type: application/json' \
  -d '{"document": "# Hello from Claude", "author": "claude"}'
```

Or have the agent join via CLI for file-based sync:

```sh
collabmd join abc123 --name claude --file shared.md
```

## Other Commands

```sh
collabmd history abc123       # View version history
collabmd restore abc123 2     # Restore a previous version
collabmd status abc123        # Check who's online
collabmd uninstall            # Remove collabmd
```

### Sync Modes

```sh
# Default: CRDT auto-merge — concurrent edits merge automatically
collabmd join abc123 --name alice --mode crdt

# Overwrite mode — last save wins (simpler, no merging)
collabmd join abc123 --name alice --mode overwrite
```

Both modes create version snapshots on every edit. Use `collabmd history` and `collabmd restore` to roll back.

### How Sessions Work

The CLI stays running while you're in a room — it holds the WebSocket connection and file watcher. Edit your file normally, changes sync in the background. Ctrl+C to leave.

- **Room = the code, not the creator.** If Alice creates a room and leaves, Bob keeps working. Alice can rejoin later with the same code.
- **Rooms stay alive** as long as at least one person is connected. When the last person leaves, a 30-minute countdown starts. If nobody rejoins, the room is deleted.
- **Idle timeout** — rooms with no edits for 4 hours are cleaned up automatically.
- **Silence logs** — run with `2>/dev/null` to suppress status messages, or background it with `&`.

## Default Server

The CLI and web editor connect to **`https://collab-md.fly.dev`** by default.

### What you should know

- **No authentication** — anyone with a room code can join and edit. Room codes are random 6-character hex strings (16M possibilities), so they're not guessable, but treat them like a shared link.
- **No persistence** — rooms auto-delete after 4 hours of inactivity (or 30 minutes after the last person leaves). Nothing is stored permanently.
- **No encryption at rest** — content is transmitted over TLS (HTTPS/WSS) but the server sees room contents in memory. Don't use it for secrets or sensitive data.
- **Rate limited** — 120 room creates per minute per IP, 60 document updates per minute per user, 200 max active rooms.
- **Content is ephemeral** — no logging, no database, no disk storage. When a room closes, the content is gone.

### For private or sensitive work, self-host

```sh
# Per-command
collabmd create --name alice --server https://your-server.com

# Or set globally
export COLLAB_SERVER=https://your-server.com
```

## Self-Hosting

### Option 1: Docker (recommended)

```sh
SECRET=$(openssl rand -hex 64)
docker build -t collab-md .
docker run -d \
  -e SECRET_KEY_BASE="$SECRET" \
  -e PHX_HOST=your-domain.com \
  -p 4000:4000 \
  collab-md
```

### Option 2: Deploy to Fly.io

```sh
fly launch
fly secrets set SECRET_KEY_BASE=$(openssl rand -hex 64)
fly deploy
```

### Option 3: Run from source

```sh
git clone https://github.com/justinwlin/collab-md.git
cd collab-md && mix deps.get
mix phx.server  # development
```

### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | **Yes** (prod) | — | 64+ char secret. Generate with `openssl rand -hex 64` |
| `PHX_HOST` | No | `example.com` | Your server's domain name |
| `PORT` | No | `4000` | HTTP listen port |

## How It Works

1. **File watchers** (FSEvents/inotify) detect local edits instantly — no polling
2. **CRDT sync** (Yjs) — edits are encoded as CRDT operations. Concurrent edits merge automatically
3. **Web editor** — CodeMirror 6 in the browser with Yjs, connected via Phoenix channels
4. **Thin relay server** — stores and broadcasts binary CRDT updates. Plain text maintained for REST API
5. **Version snapshots** on every edit — view with `collabmd history`, restore with `collabmd restore`

## Development

```sh
mix phx.server              # Start server
mix test                    # Elixir tests
cd cli-rust && cargo test   # Rust tests
./test_e2e.sh               # Full E2E suite
```

## Uninstall

```sh
collabmd uninstall
```

Or manually: `rm ~/.local/bin/collabmd`
