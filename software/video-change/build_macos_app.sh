#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VideoChange"
APP_DIR="$ROOT_DIR/${APP_NAME}.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
BUILD_DIR="$ROOT_DIR/.build/video-change-app"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"
SWIFT_SOURCES=("$ROOT_DIR"/macos-app/*.swift)

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"
rm -f "$MACOS_DIR/$APP_NAME"

cat >"$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>VideoChange</string>
  <key>CFBundleIdentifier</key>
  <string>local.cyril.videochange</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VideoChange</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR" \
swiftc \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -o "$MACOS_DIR/$APP_NAME" \
  "${SWIFT_SOURCES[@]}"

chmod +x "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/detect_scene_changes.py" "$RESOURCES_DIR/detect_scene_changes.py"
ln -sfn ../../../.venv "$RESOURCES_DIR/venv"

echo "Built: $APP_DIR"
echo "Run: open \"$APP_DIR\""
