#!/bin/bash
# Development launcher. Every dev/review/capture/smoke run stays off the
# REAL save directory: --nosave disables the save service outright (no
# boot modal, no autosave, no writes), and TOWER_SAVE_DIR redirects the
# slot directory anyway so a dev run that DOES exercise persistence
# lands in user://saves_dev/, never in user://saves/. The live saves
# belong to tools/run.sh and the app launcher.
set -euo pipefail
cd "$(dirname "$0")/.."
export TOWER_SAVE_DIR="${TOWER_SAVE_DIR:-user://saves_dev}"
exec tools/Godot.app/Contents/MacOS/Godot --path . "$@" -- --nosave
