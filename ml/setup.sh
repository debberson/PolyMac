#!/bin/sh
# One-time setup: creates ml/.venv with the training dependencies.
set -e
cd "$(dirname "$0")"
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
  for candidate in python3.11 python3.12 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then PYTHON="$candidate"; break; fi
  done
fi
echo "Using $($PYTHON --version) at $(command -v $PYTHON)"
"$PYTHON" -m venv .venv
.venv/bin/pip install --upgrade pip --quiet
.venv/bin/pip install -r requirements.txt
echo
echo "Done. Train with: ml/train.sh"
