#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DESTINATION="$HOME/.local/bin"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
LABEL="com.codex.voice-hotkey"
OLD_APP="$HOME/Applications/Codex Voice Hotkey.app"
APP="$HOME/Applications/cliMC.app"
AUTO_CODESIGN_IDENTITY="$(
  security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development:/ { print $2; exit }'
)"
CODESIGN_IDENTITY="${CODEX_VOICE_CODESIGN_IDENTITY:-${AUTO_CODESIGN_IDENTITY:--}}"

swift build -c release --package-path "$ROOT"
mkdir -p "$DESTINATION"
cp "$ROOT/.build/release/codex-voice-hotkey" "$DESTINATION/codex-voice-hotkey"
chmod +x "$DESTINATION/codex-voice-hotkey"

if [[ -d "$OLD_APP" && ! -d "$APP" ]]; then
  mv "$OLD_APP" "$APP"
fi

if [[ -d "$APP" ]]; then
  rm -rf "$APP"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/.build/release/codex-voice-hotkey" "$APP/Contents/MacOS/codex-voice-hotkey"
cp "$ROOT/scripts/web-server.py" "$APP/Contents/Resources/web-server.py"
chmod +x "$APP/Contents/Resources/web-server.py"
cp "$ROOT/app/cliMC.png" "$APP/Contents/Resources/cliMC.png"

rm -f "$APP/Contents/MacOS/cliMC"

ICONSET="$ROOT/.build/cliMC.iconset"
mkdir -p "$ICONSET"
find "$ICONSET" -type f -delete
sips -z 16 16 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ROOT/app/cliMC.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/cliMC.icns"
if ! codesign --force --sign "$CODESIGN_IDENTITY" "$APP"; then
  echo "Warning: codesign with identity '$CODESIGN_IDENTITY' failed; falling back to ad hoc signing."
  codesign --force --sign - "$APP"
fi

mkdir -p "$LAUNCH_AGENTS"
cp "$ROOT/launchd/$LABEL.plist" "$LAUNCH_AGENTS/$LABEL.plist"
python3 - "$LAUNCH_AGENTS/$LABEL.plist" "$APP" <<'PY'
import plistlib
import sys

plist_path, app_path = sys.argv[1:]
with open(plist_path, "rb") as source:
    launch_agent = plistlib.load(source)
launch_agent["ProgramArguments"] = ["/usr/bin/open", "-gj", "-a", app_path]
with open(plist_path, "wb") as destination:
    plistlib.dump(launch_agent, destination)
PY
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS/$LABEL.plist"

echo "Installed: $DESTINATION/codex-voice-hotkey"
echo "Installed app: $APP"
echo "Started cliMC background service: $LABEL"
echo "It will also start automatically after you log in."
