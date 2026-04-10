#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DEST_DIR="$HOME/86Box"

mkdir -p "$BUILD_DIR"

cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DUSE_QT6=ON -DVNC=ON

ninja -j$(nproc) -C "$BUILD_DIR"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
DEST_TIME="$DEST_DIR/86Box-dev-$TIMESTAMP"
DEST_LATEST="$DEST_DIR/86Box-dev-latest"

cp "$BUILD_DIR/src/86Box" "$DEST_TIME"
echo "Copied to $DEST_TIME"

cp "$BUILD_DIR/src/86Box" "$DEST_LATEST"
echo "Copied to $DEST_LATEST"