#!/bin/bash
# Builds SideTab.app, closes any copy that is running, and opens the new one.
# The app lives in the menu bar; its log is in ~/Library/Logs/SideTab.log.
set -euo pipefail
cd "$(dirname "$0")"

bash ./build.sh
pkill -x SideTab 2>/dev/null || true
sleep 0.5
open SideTab.app
echo "SideTab is in the menu bar."
