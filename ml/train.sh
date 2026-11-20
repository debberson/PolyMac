#!/bin/sh
# Trains the model from data/sessions and installs it at data/models/PolyMacModel.mlmodel.
# Any extra arguments are passed to train.py (see: ml/train.sh --help).
set -e
cd "$(dirname "$0")"
if [ ! -x .venv/bin/python ]; then
  echo "Run ml/setup.sh first (one-time)." >&2
  exit 1
fi
exec .venv/bin/python -I train.py "$@"
