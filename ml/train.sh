#!/bin/sh
# Trains the model from the app's recorded sessions and installs it in that data folder's
# models/PolyMacModel.mlmodel. Any extra arguments are passed to train.py (ml/train.sh --help).
set -e
cd "$(dirname "$0")"
VENV="${POLYMAC_VENV:-$HOME/.polymac/ml-venv}"
if [ ! -x "$VENV/bin/python" ]; then
  echo "Run ml/setup.sh first (one-time)." >&2
  exit 1
fi
exec "$VENV/bin/python" -I train.py "$@"
