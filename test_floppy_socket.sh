#!/bin/bash
# test_floppy_socket.sh - Floppy API test server for 86Box
#
# Acts as a VM manager: starts a socket server, waits for 86Box to connect,
# then accepts floppy commands interactively or from another terminal.
#
# Usage:
#   Start the server:
#     ./test_floppy_socket.sh
#
#   Launch 86Box pointing at it (in another terminal):
#     VMM_86BOX_SOCKET=/tmp/86box-test.sock ./build/src/86Box -P ~/86Box/vms/myvm
#
#   Send commands from another terminal while the server is running:
#     ./test_floppy_socket.sh send insert [drive] <image-path>
#     ./test_floppy_socket.sh send eject [drive]
#     ./test_floppy_socket.sh send refresh [drive]
#     ./test_floppy_socket.sh send quit
#
#   Or type the same commands interactively at the server's prompt.
#   drive defaults to 0 if not specified.

SOCKET="/tmp/86box-test.sock"
CMDPIPE="/tmp/86box-test.cmd"

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

echo "86Box floppy test server"
echo "Socket:  $SOCKET"
echo "Command pipe: $CMDPIPE"
echo ""
echo "Launch 86Box with:"
echo "  VMM_86BOX_SOCKET=$SOCKET ./build/src/86Box -P ~/86Box/vms/myvm"
echo ""
echo "Send commands from another terminal:"
echo "  ./test_floppy_socket.sh send insert ~/86Box/floppies/myimage.vfd"
echo "  ./test_floppy_socket.sh send eject"
echo "  ./test_floppy_socket.sh send refresh 1"
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
print("Commands: insert [drive] <image-path> | eject [drive] | refresh [drive] | quit")
print("")

def send(conn, payload):
    json_bytes = json.dumps(payload).encode("utf-8")
    conn.sendall(struct.pack(">I", len(json_bytes)) + json_bytes)
    print(f"\r  Sent: {json.dumps(payload)}\n> ", end="", flush=True)

def handle_command(line, conn):
    line = line.strip()
    if not line:
        return True

    parts = line.split()
    cmd = parts[0].lower()

    if cmd == "quit":
        return False

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
buf = ""
running = True
while running:
    # Monitor stdin and the command pipe simultaneously
    readable, _, _ = select.select([sys.stdin, pipe], [], [])
    for src in readable:
        line = src.readline()
        if not line:
            continue
        if src is pipe:
            # Command from external sender — echo it so the server terminal shows it
            print(f"\r[pipe] {line.strip()}")
        running = handle_command(line, conn)
        if running:
            print("> ", end="", flush=True)

pipe.close()
conn.close()
server.close()
print("Done.")
EOF
