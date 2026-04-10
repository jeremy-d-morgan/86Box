#!/bin/bash
# 86box_ctl.sh - 86Box VM control server
#
# Acts as a VM manager: creates a socket server, waits for 86Box to connect,
# then accepts control commands interactively or from another terminal.
#
# Usage:
#   Start the server:
#     ./86box_ctl.sh
#
#   Launch 86Box pointing at it (in another terminal):
#     VMM_86BOX_SOCKET=/tmp/86box-ctl.sock ./build/src/86Box -P ~/86Box/vms/myvm
#
#   Send commands from another terminal while the server is running:
#     ./86box_ctl.sh send <command> [args...]
#
# Commands:
#   pause                              Toggle pause
#   reset                              Hard reset
#   cad                                Send Ctrl+Alt+Del
#   settings                           Show settings dialog
#   shutdown                           Request shutdown (with prompt)
#   shutdown!                          Force shutdown (no prompt)
#   status                             Request status
#   insert [drive] <image-path>        Insert floppy image (drive defaults to 0)
#   eject  [drive]                     Eject floppy
#   refresh [drive]                    Eject and re-insert current floppy image
#   quit                               Stop the server

SOCKET="/tmp/86box-ctl.sock"
CMDPIPE="/tmp/86box-ctl.cmd"

# --- send mode: write a command to the running server's pipe ---
if [[ "$1" == "send" ]]; then
    shift
    if [[ ! -p "$CMDPIPE" ]]; then
        echo "Error: no server running (pipe not found: $CMDPIPE)" >&2
        exit 1
    fi
    echo "$*" > "$CMDPIPE"
    exit 0
fi

# --- server mode ---
set -e

rm -f "$SOCKET" "$CMDPIPE"
mkfifo "$CMDPIPE"

cleanup() {
    rm -f "$SOCKET" "$CMDPIPE"
}
trap cleanup EXIT

echo "86Box control server"
echo "Socket:       $SOCKET"
echo "Command pipe: $CMDPIPE"
echo ""
echo "Launch 86Box with:"
echo "  VMM_86BOX_SOCKET=$SOCKET ./build/src/86Box -P ~/86Box/vms/myvm"
echo ""
echo "Send commands from another terminal:"
echo "  ./86box_ctl.sh send pause"
echo "  ./86box_ctl.sh send insert ~/86Box/floppies/myimage.vfd"
echo "  ./86box_ctl.sh send eject 1"
echo ""
echo "Waiting for 86Box to connect..."

python3 - "$SOCKET" "$CMDPIPE" <<'EOF'
import sys
import socket
import struct
import json
import os
import select
import readline  # enables arrow keys and history at the prompt

sock_path = sys.argv[1]
pipe_path = sys.argv[2]

# Reopen stdin from the terminal — the heredoc consumed the original stdin
sys.stdin = open('/dev/tty')

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)

conn, _ = server.accept()
print("86Box connected.\n")
print("Commands: pause | reset | cad | settings | shutdown | shutdown! | status")
print("          insert [drive] <image> | eject [drive] | refresh [drive] | quit")
print("")

def send(conn, payload):
    json_bytes = json.dumps(payload).encode("utf-8")
    conn.sendall(struct.pack(">I", len(json_bytes)) + json_bytes)
    print(f"\r  Sent: {json.dumps(payload)}\n> ", end="", flush=True)

def simple(conn, message):
    send(conn, {"type": "VMManager", "message": message})

def handle_command(line, conn):
    line = line.strip()
    if not line:
        return True

    parts = line.split()
    cmd = parts[0].lower()

    if cmd == "quit":
        return False
    elif cmd == "pause":
        simple(conn, "Pause")
    elif cmd == "reset":
        simple(conn, "ResetVM")
    elif cmd == "cad":
        simple(conn, "CtrlAltDel")
    elif cmd == "settings":
        simple(conn, "ShowSettings")
    elif cmd == "shutdown":
        simple(conn, "RequestShutdown")
    elif cmd == "shutdown!":
        simple(conn, "ForceShutdown")
    elif cmd == "status":
        simple(conn, "RequestStatus")
    elif cmd in ("insert", "eject", "refresh"):
        drive = 0
        args = parts[1:]
        if args and args[0].isdigit() and 0 <= int(args[0]) <= 3:
            drive = int(args[0])
            args = args[1:]

        if cmd == "insert":
            if not args:
                print("  Error: insert requires an image path")
                return True
            path = os.path.realpath(args[0])
            if not os.path.isfile(path):
                print(f"  Error: file not found: {path}")
                return True
            send(conn, {
                "type":    "VMManager",
                "message": "FloppyInsert",
                "params":  {"drive": drive, "path": path, "writeProtect": False},
            })
        elif cmd == "eject":
            send(conn, {
                "type":    "VMManager",
                "message": "FloppyEject",
                "params":  {"drive": drive},
            })
        elif cmd == "refresh":
            send(conn, {
                "type":    "VMManager",
                "message": "FloppyRefresh",
                "params":  {"drive": drive},
            })
    else:
        print(f"  Unknown command: {cmd}")

    return True

# Open the pipe in non-blocking read mode
pipe_fd = os.open(pipe_path, os.O_RDONLY | os.O_NONBLOCK)
pipe = os.fdopen(pipe_fd, 'r')

print("> ", end="", flush=True)
running = True
while running:
    readable, _, _ = select.select([sys.stdin, pipe], [], [])
    for src in readable:
        line = src.readline()
        if not line:
            continue
        if src is pipe:
            print(f"\r[pipe] {line.strip()}")
        running = handle_command(line, conn)
        if running:
            print("> ", end="", flush=True)

pipe.close()
conn.close()
server.close()
print("Done.")
EOF
