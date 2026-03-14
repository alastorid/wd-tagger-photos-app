#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$APP_DIR/env"

cd "$APP_DIR"

# Create venv if missing
if [ ! -d "$VENV_DIR" ]; then
  echo "[*] Creating virtual environment..."
  python3 -m venv "$VENV_DIR"
fi

# Activate venv
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

if [ -f requirements.txt ]; then
  echo "[*] Installing additional requirements from requirements.txt..."
  python -m pip install --upgrade pip
  python -m pip install -r requirements.txt
fi

# Daemon bind settings
export WD_LISTEN="${WD_LISTEN:-127.0.0.1}"
export WD_PORT="${WD_PORT:-5566}"

echo "[*] Starting daemon on http://${WD_LISTEN}:${WD_PORT} ..."
exec python server.py --listen "$WD_LISTEN" --port "$WD_PORT"
