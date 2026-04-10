#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

cleanup() {
    if [ -n "${SERVER_PID:-}" ]; then
        echo "==> Stopping Phoenix server (pid $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "==> Installing Elixir dependencies..."
mix deps.get --quiet 2>/dev/null

echo "==> Starting Phoenix server on port 4000..."
MIX_ENV=dev mix phx.server &
SERVER_PID=$!

echo "==> Waiting for server to be ready..."
for i in $(seq 1 30); do
    if curl -sf -o /dev/null -X POST "http://localhost:4000/api/rooms" 2>/dev/null; then
        echo "==> Server is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Server failed to start within 30s"
        exit 1
    fi
    sleep 1
done

echo "==> Running Rust unit tests..."
cd cli-rust
cargo test --lib -- --nocapture
echo ""

echo "==> Running E2E integration tests..."
COLLAB_TEST_SERVER="http://localhost:4000" cargo test --test e2e -- --nocapture

echo ""
echo "==> All tests passed!"
