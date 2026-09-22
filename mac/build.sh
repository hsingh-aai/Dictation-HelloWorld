#!/bin/bash
# Builds, bundles, signs and installs Dictation Hello to /Applications.
#
#   ./build.sh              dev build:  com.example.dictationhello.dev  "Dictation Hello Dev"
#   ./build.sh --release    shipping:   com.example.dictationhello      "Dictation Hello"
#   ./build.sh --no-install leave the bundle in build/ (TCC won't register it there)
#
# Dev is the default so a configuration added later can't disturb a shipped install. The two
# builds have separate bundle ids, Privacy rows and Keychain items. Bundle ids are all-lowercase:
# TCC records the Accessibility client in lowercase and a mixed-case id never matches it.
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VERSION="0.1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

FLAVOR=dev
INSTALL=1
for arg in "$@"; do
  case "$arg" in
    --release) FLAVOR=release ;;
    --no-install) INSTALL=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$FLAVOR" == release ]]; then
  BUNDLE_ID="com.example.dictationhello"; NAME="Dictation Hello"; CONFIG=release
else
  BUNDLE_ID="com.example.dictationhello.dev"; NAME="Dictation Hello Dev"; CONFIG=debug
fi

# A stable identity keeps the Microphone and Accessibility grants across rebuilds. Ad-hoc
# signatures derive identity from the binary hash, so every rebuild would revoke them.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  for candidate in "Apple Development" "Dictation Flow Local"; do
    if security find-identity -v -p codesigning | grep -q "\"$candidate"; then
      IDENTITY="$(security find-identity -v -p codesigning | grep "\"$candidate" | head -1 | sed -E 's/.*"(.*)"/\1/')"
      break
    fi
  done
fi

echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG" --product DictationHello
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DictationHello" "$APP/Contents/MacOS/DictationHello"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>DictationHello</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>$NAME listens only while your dictation shortcut is active, and sends that audio to AssemblyAI to transcribe it.</string>
</dict>
</plist>
PLIST

sign() {
  local target="$1"
  if [[ -z "$IDENTITY" ]]; then
    echo "⚠︎ no signing identity found — ad-hoc signing; permissions will reset on every rebuild" >&2
    codesign --force --sign - --entitlements Support/DictationHello.entitlements --options runtime "$target"
    return
  fi
  local requirement=()
  # Apple Development: pin the team, not the leaf's Common Name, which rotates ~yearly and
  # silently orphans the grant.
  if [[ "$IDENTITY" == "Apple Development"* ]]; then
    local team
    team="$(security find-certificate -c "$IDENTITY" -p | openssl x509 -noout -subject -nameopt multiline | awk -F' = ' '/organizationalUnitName/{print $2; exit}')"
    requirement=(-r="designated => identifier \"$BUNDLE_ID\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\"")
  fi
  # Inside-out: nested code first (none today — SwiftPM links statically), then the bundle.
  find "$target/Contents" -name '*.dylib' -o -name '*.framework' | while read -r nested; do
    codesign --force --sign "$IDENTITY" --options runtime "$nested"
  done
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --entitlements Support/DictationHello.entitlements \
    --options runtime ${requirement[@]+"${requirement[@]}"} "$target"
}

echo "▸ sign ($([[ -n "$IDENTITY" ]] && echo "$IDENTITY" || echo ad-hoc))"
sign "$APP"

if [[ "$INSTALL" == 1 ]]; then
  # TCC refuses to register apps in DerivedData, build dirs or /tmp, so the toggles never appear.
  DEST="/Applications/$NAME.app"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 0.5
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  sign "$DEST"
  echo "▸ installed $DEST"
  codesign -d -r- "$DEST" 2>&1 | grep designated || true
  echo "  open with:  open \"$DEST\""
else
  echo "▸ built $APP"
fi
