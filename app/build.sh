#!/bin/sh
# Build PicoClaude.app (menu bar app) into app/build/ and sign it.
#
#   app/build.sh
#   PICO_CLAUDE_SIGN_IDENTITY="Apple Development: Someone (XXXXXXXXXX)" app/build.sh
#
# Signing with a stable developer identity matters: macOS ties the Local
# Network permission to it, so rebuilds don't trigger the prompt again.
set -e
cd "$(dirname "$0")"
IDENTITY="${PICO_CLAUDE_SIGN_IDENTITY:-Apple Development: Chris Carline (44LK3X8YQA)}"
BUNDLE_ID="com.chriscarline.PicoClaude"
APP="build/PicoClaude.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/PicoClaude" "$APP/Contents/MacOS/PicoClaude"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>PicoClaude</string>
  <key>CFBundleDisplayName</key><string>PicoClaude</string>
  <key>CFBundleExecutable</key><string>PicoClaude</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>PicoClaude talks to the MQTT broker on your network to collect Claude Code usage from your other machines and send it to the Pico display.</string>
</dict>
</plist>
PLIST

# Several certificates can share one name; codesign then refuses the name as
# ambiguous, so resolve it to the first matching hash.
HASH="$(security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" | head -1 | awk '{print $2}')"
[ -n "$HASH" ] || { echo "no valid signing identity named: $IDENTITY" >&2; exit 1; }
codesign --force --sign "$HASH" --identifier "$BUNDLE_ID" --options runtime "$APP" || {
  echo "signing failed: codesign could not use the key in your login keychain." >&2
  if [ -n "$SSH_CONNECTION" ]; then
    echo "Over SSH the keychain is locked. Unlock it, then run this again:" >&2
    echo "  security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
  else
    echo "Unlock the login keychain, and if macOS asks to let codesign use the key," >&2
    echo "choose Always Allow." >&2
  fi
  exit 1
}
codesign --verify --strict "$APP"
echo "built $PWD/$APP"
