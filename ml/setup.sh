#!/bin/sh
# One-time setup: creates the training environment (scikit-learn, pandas, coremltools).
# It lives outside the repo, in ~/.polymac/ml-venv, because iCloud Drive offloads files in
# ~/Documents and Python then stalls for minutes downloading its own packages. Set POLYMAC_VENV
# to put it somewhere else.
set -e
cd "$(dirname "$0")"
VENV="${POLYMAC_VENV:-$HOME/.polymac/ml-venv}"
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
  for candidate in python3.11 python3.12 python3.10 python3; do
    path="$(command -v "$candidate" 2>/dev/null)" || continue
    # Skip any virtual environment's Python (an activated one comes first on PATH); build from the real install.
    [ -f "$(dirname "$(dirname "$path")")/pyvenv.cfg" ] && continue
    PYTHON="$path"
    break
  done
fi
if [ -z "$PYTHON" ]; then
  echo "No Python 3 found. Install one (for example: brew install python@3.11) and run this again." >&2
  exit 1
fi
echo "Using $("$PYTHON" --version) at $PYTHON"
echo "Creating $VENV"
mkdir -p "$(dirname "$VENV")"
"$PYTHON" -m venv --clear "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip --quiet
"$VENV/bin/python" -m pip install -r requirements.txt
echo
if [ -d .venv ]; then
  echo "The old environment in ml/.venv is no longer used; you can delete it."
fi
echo "Done. Train with: ml/train.sh"
