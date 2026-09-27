#!/bin/bash
# Phase 0 acceptance probe: proves the tower scenario runs on the SHARED
# rules engine, headlessly and deterministically. Exit 0 on success.
set -euo pipefail
cd "$(dirname "$0")/.."
tools/Godot.app/Contents/MacOS/Godot --headless --path . \
	-s res://tools_dev/probe_sim.gd
