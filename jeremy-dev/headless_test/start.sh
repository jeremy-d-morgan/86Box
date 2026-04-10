#!/usr/bin/env bash
#
# Start 86Box in headless+VNC mode with noVNC web viewer.
#
# Usage: ./start.sh /path/to/vm
#
# Opens:
#   - 86Box headless with libvncserver VNC renderer on port 5900
#   - noVNC web viewer on http://localhost:8080
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EMUBIN="$HOME/86Box/86Box-dev-latest"

VM_PATH="${1:?Usage: $0 /path/to/vm}"
VNC_PORT="${VNC_PORT:-5900}"
WEB_PORT="${WEB_PORT:-8080}"

if [ ! -f "$EMUBIN" ]; then
    echo "Error: 86Box binary not found at $EMUBIN"
    echo "       Run cmake --build build/ first."
    exit 1
fi

cleanup() {
    echo ""
    echo "Shutting down..."
    [ -n "$EMU_PID" ] && kill "$EMU_PID" 2>/dev/null
    [ -n "$WEB_PID" ] && kill "$WEB_PID" 2>/dev/null
    # Wait up to 5s for 86Box to exit cleanly, then force-kill
    for i in $(seq 1 10); do
        [ -n "$EMU_PID" ] && kill -0 "$EMU_PID" 2>/dev/null || break
        sleep 0.5
    done
    [ -n "$EMU_PID" ] && kill -9 "$EMU_PID" 2>/dev/null
    wait 2>/dev/null
    echo "Done."
}
trap cleanup EXIT INT TERM

# Source nvm if available
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Start noVNC web server + websockify proxy
node "$SCRIPT_DIR/server.js" &
WEB_PID=$!

# Give the web server a moment to start
sleep 0.5

# Start 86Box headless. The offscreen QPA provides a functioning event loop
# with no display dependency. The libvncserver VNC renderer is auto-selected
# when headless mode is active and USE_VNC was compiled in.
echo "Starting 86Box (VNC on port $VNC_PORT)..."
QT_QPA_PLATFORM="offscreen" \
    "$EMUBIN" --headless -P "$VM_PATH" &
EMU_PID=$!

echo ""
echo "  View in browser: http://localhost:$WEB_PORT"
echo "  VM path:         $VM_PATH"
echo "  86Box PID:       $EMU_PID"
echo ""

wait "$EMU_PID" 2>/dev/null
