#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DEST_DIR="$HOME/86Box"

mkdir -p "$BUILD_DIR"

cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DUSE_QT6=ON

ninja -C "$BUILD_DIR"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
DEST="$DEST_DIR/86Box-dev-$TIMESTAMP"
cp "$BUILD_DIR/src/86Box" "$DEST"
echo "Copied to $DEST"
