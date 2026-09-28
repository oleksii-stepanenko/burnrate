#!/bin/zsh
# Builds dist/Token Counter.app (ad-hoc signed). Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/Token Counter.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TokenCounter "$APP/Contents/MacOS/TokenCounter"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Token Counter</string>
  <key>CFBundleDisplayName</key><string>Token Counter</string>
  <key>CFBundleIdentifier</key><string>dev.local.tokencounter</string>
  <key>CFBundleExecutable</key><string>TokenCounter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Launch agent used by "Open at login" (registered from the app via SMAppService).
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/dev.local.tokencounter.agent.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.local.tokencounter.agent</string>
  <key>BundleProgram</key><string>Contents/MacOS/TokenCounter</string>
  <key>ProgramArguments</key><array><string>TokenCounter</string><string>--background</string></array>
  <key>AssociatedBundleIdentifiers</key><array><string>dev.local.tokencounter</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
AGENT

# App icon, drawn with AppKit so there's no binary asset in the repo.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make_icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep -s - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Token Counter.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Token Counter.app"
  # Restart the running login-item instance so it picks up the new build.
  if launchctl print "gui/$(id -u)/dev.local.tokencounter.agent" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/dev.local.tokencounter.agent" && echo "Restarted the login item"
  fi
fi
