#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="MemorySpy"
APP_BUNDLE="$ROOT_DIR/${APP_NAME}.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
MODULE_CACHE="/tmp/memoryspy-module-cache"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE"

swift -module-cache-path "$MODULE_CACHE" "$ROOT_DIR/Scripts/generate_icon.swift" "$ROOT_DIR/Resources/AppIcon.icns"

echo "Compiling $APP_NAME (Release, arm64)..."
swiftc \
    -O \
    -whole-module-optimization \
    -target arm64-apple-macosx15.0 \
    -module-cache-path "$MODULE_CACHE" \
    -framework AppKit \
    -framework ServiceManagement \
    "$ROOT_DIR/Sources/MemoryMonitor.swift" \
    "$ROOT_DIR/Sources/RingIconRenderer.swift" \
    "$ROOT_DIR/Sources/PopoverViewController.swift" \
    "$ROOT_DIR/Sources/AppDelegate.swift" \
    "$ROOT_DIR/Sources/main.swift" \
    -o "$MACOS_DIR/$APP_NAME"

strip -x "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

BINARY_SIZE=$(ls -lh "$MACOS_DIR/$APP_NAME" | awk '{print $5}')
echo "Built $APP_BUNDLE (binary size: $BINARY_SIZE)"
