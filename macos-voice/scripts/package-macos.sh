#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PACKAGE_ROOT="${SCRIPT_DIR:h}"
REPO_ROOT="${PACKAGE_ROOT:h}"
OUTPUT_DIR="$REPO_ROOT/dist"
ARCHIVE_NAME="cliMC-macos-arm64.zip"
CHECKSUM_NAME="$ARCHIVE_NAME.sha256"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/climc-package.XXXXXX")"
APP="$STAGING_ROOT/cliMC.app"
UNPACKED="$STAGING_ROOT/unpacked"
ICONSET="$STAGING_ROOT/cliMC.iconset"

cleanup() {
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

swift build -c release --package-path "$PACKAGE_ROOT"

EXECUTABLE="$PACKAGE_ROOT/.build/release/codex-voice-hotkey"
ARCHITECTURE="$(file "$EXECUTABLE")"
[[ "$ARCHITECTURE" == *arm64* ]]
[[ "$ARCHITECTURE" != *x86_64* ]]

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET" "$OUTPUT_DIR"
cp "$PACKAGE_ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$EXECUTABLE" "$APP/Contents/MacOS/codex-voice-hotkey"
cp "$PACKAGE_ROOT/scripts/web-server.py" "$APP/Contents/Resources/web-server.py"
chmod +x "$APP/Contents/Resources/web-server.py"
cp "$PACKAGE_ROOT/app/cliMC.png" "$APP/Contents/Resources/cliMC.png"

sips -z 16 16 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$PACKAGE_ROOT/app/cliMC.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/cliMC.icns"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=4 "$APP"

ARCHIVE="$OUTPUT_DIR/$ARCHIVE_NAME"
CHECKSUM="$OUTPUT_DIR/$CHECKSUM_NAME"
rm -f "$ARCHIVE" "$CHECKSUM"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$ARCHIVE_NAME" > "$CHECKSUM_NAME"
  shasum -a 256 -c "$CHECKSUM_NAME"
)

mkdir -p "$UNPACKED"
ditto -x -k "$ARCHIVE" "$UNPACKED"
UNPACKED_EXECUTABLE="$UNPACKED/cliMC.app/Contents/MacOS/codex-voice-hotkey"
UNPACKED_ARCHITECTURE="$(file "$UNPACKED_EXECUTABLE")"
[[ "$UNPACKED_ARCHITECTURE" == *arm64* ]]
[[ "$UNPACKED_ARCHITECTURE" != *x86_64* ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$UNPACKED/cliMC.app/Contents/Info.plist")" == "local.climc.app" ]]
codesign --verify --deep --strict --verbose=4 "$UNPACKED/cliMC.app"

echo "Package: $ARCHIVE"
echo "Checksum: $CHECKSUM"
