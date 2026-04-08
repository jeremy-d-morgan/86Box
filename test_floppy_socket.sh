#!/bin/bash
# test_floppy_socket.sh - Floppy API test server for 86Box
#
# Acts as a VM manager: starts a socket server, waits for 86Box to connect,
# then accepts interactive floppy commands.
#
# Usage:
#   1. Run this script:
#        ./test_floppy_socket.sh
#
#   2. In another terminal, launch 86Box with the printed env var:
#        VMM_86BOX_SOCKET=/tmp/86box-test.sock ./build/src/86Box -P ~/86Box/vms/myvm
#
#   3. Type commands at the prompt:
#        insert [drive] <image-path>    (drive defaults to 0)
#        eject [drive]
#        refresh [drive]
#        quit

set -e

SOCKET="/tmp/86box-test.sock"

rm -f "$SOCKET"

echo "86Box floppy test server"
echo "Socket: $SOCKET"
echo ""
echo "Launch 86Box with:"
echo "  VMM_86BOX_SOCKET=$SOCKET ./build/src/86Box -P ~/86Box/vms/myvm"
echo ""
echo "Waiting for 86Box to connect..."

python3 - "$SOCKET" <<'EOF'
import sys
import socket
import struct
import json
import os
import readline  # enables arrow keys and history at the prompt

sock_path = sys.argv[1]

# Reopen stdin from the terminal — the heredoc consumed the original stdin
sys.stdin = open('/dev/tty')

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)

conn, _ = server.accept()
print("86Box connected.\n")
print("Commands:")
print("  insert [drive] <image-path>")
print("  eject  [drive]")
print("  refresh [drive]")
print("  quit")
print("")

def send(conn, payload):
    json_bytes = json.dumps(payload).encode("utf-8")
    # QDataStream QByteArray framing: uint32 big-endian length + bytes
    conn.sendall(struct.pack(">I", len(json_bytes)) + json_bytes)
    print(f"  Sent: {json.dumps(payload)}")

while True:
    try:
        line = input("> ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        break

    if not line:
        continue

    parts = line.split()
    cmd = parts[0].lower()

    if cmd == "quit":
        break

    # Parse optional drive number
    drive = 0
    args = parts[1:]
    if args and args[0].isdigit() and 0 <= int(args[0]) <= 3:
        drive = int(args[0])
        args = args[1:]

    if cmd == "insert":
        if not args:
            print("  Error: insert requires an image path")
            continue
        path = os.path.realpath(args[0])
        if not os.path.isfile(path):
            print(f"  Error: file not found: {path}")
            continue
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

conn.close()
server.close()
os.remove(sock_path)
print("Done.")
EOF
