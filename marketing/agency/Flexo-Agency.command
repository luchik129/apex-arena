#!/usr/bin/env bash
# Double-click: opens the agency panel (city + Start/Stop). Close this window to quit the panel.
cd "$(dirname "$0")/../.." || exit 1
command -v claude >/dev/null || { echo "Claude Code (claude) is not installed"; read -r; exit 1; }
(sleep 1; open "http://localhost:8787") &
exec python3 marketing/agency/server.py
