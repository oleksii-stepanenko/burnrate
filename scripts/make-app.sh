#!/usr/bin/env bash
# make-app.sh — build Burnrate and assemble it into a real .app bundle.
#
# The bundle carries the launch agent used by "Open at login" (SMAppService) and
# a stable bundle id, so it has to be a proper .app rather than a bare binary.
#
# Usage: ./scripts/make-app.sh [--release] [--install]
#   --release   build with optimizations (default: debug)
#   --install   also copy the result into /Applications (and restart the login item)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=debug
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --install) INSTALL=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

APP_NAME="Burnrate"
BUNDLE_ID="io.stepanenko.Burnrate"
AGENT_LABEL="$BUNDLE_ID.agent"
# CI overrides these from the git tag; local builds get a placeholder.
VERSION="${BURNRATE_VERSION:-1.0.0}"
BUILD="${BURNRATE_BUILD:-1}"
APP="$ROOT/build/$APP_NAME.app"

echo "Building ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG" --product Burnrate

BIN="$(swift build -c "$CONFIG" --show-bin-path)"

echo "Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"

cp "$BIN/Burnrate" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>         <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>          <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>          <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>$VERSION</string>
    <key>CFBundleVersion</key>             <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>      <string>14.0</string>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.developer-tools</string>
    <!-- Not sandboxed: the whole job is reading the session logs other agents
         write under ~/.claude, ~/.pi and ~/.omp. -->
</dict>
</plist>
PLIST

# Launch agent for "Open at login". launchd starts the app with --background (menu bar
# only) and restarts it after a crash, but not after a normal Quit.
cat > "$APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                       <string>$AGENT_LABEL</string>
    <key>BundleProgram</key>               <string>Contents/MacOS/$APP_NAME</string>
    <key>ProgramArguments</key>            <array><string>$APP_NAME</string><string>--background</string></array>
    <key>AssociatedBundleIdentifiers</key> <array><string>$BUNDLE_ID</string></array>
    <key>RunAtLoad</key>                   <true/>
    <key>KeepAlive</key>                   <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key>                 <string>Interactive</string>
    <key>LimitLoadToSessionType</key>      <string>Aqua</string>
</dict>
</plist>
AGENT

# The icon is drawn with AppKit, so there is no binary asset in the repo.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature for local builds. Releases are re-signed in CI with the stable
# self-signed certificate (see .github/workflows/release.yml).
codesign --force --deep --sign - "$APP" 2>/dev/null \
  || echo "warning: codesign failed; the app will still run"

echo "Built: $APP"

if [[ $INSTALL -eq 1 ]]; then
  echo "Installing to /Applications …"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  echo "Installed: /Applications/$APP_NAME.app"
  # Restart the running login-item instance so it picks up the new build.
  if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL" && echo "Restarted the login item"
  fi
fi

echo
echo "Run it with:   open '$APP'"
