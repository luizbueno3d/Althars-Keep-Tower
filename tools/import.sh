#!/bin/bash
# One-time asset import pass. Headless GAME runs cannot import GLBs, so
# a fresh clone needs this once (same constraint Althar's Keep hit).
set -euo pipefail
cd "$(dirname "$0")/.."
tools/Godot.app/Contents/MacOS/Godot --headless --editor --quit --path .
echo "import pass complete"
