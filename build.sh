#!/bin/bash
# Builds SideTab.app. Needs Xcode or Apple's Command Line Tools.
#   bash build.sh            build SideTab.app in this folder
#   bash build.sh install    build, copy to /Applications and open it
# Compiler output is also saved to build.log.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "The Swift compiler isn't installed. Run this once, then try again:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

app=SideTab.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/web"

echo "Compiling SideTab..."
swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -import-objc-header Sources/CGVirtualDisplay.h \
  Sources/*.swift \
  -o "$app/Contents/MacOS/SideTab" 2>&1 | tee build.log

cp Info.plist "$app/Contents/Info.plist"
cp web/index.html "$app/Contents/Resources/web/index.html"

if [ ! -f Resources/AppIcon.icns ] || [ Tools/icon-1024.png -nt Resources/AppIcon.icns ]; then
  bash Tools/make-icon.sh || echo "Couldn't draw the app icon; building without it."
fi
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi

# Sign with a fixed local certificate so the screen recording permission
# survives rebuilds. Falls back to an ad-hoc signature if that doesn't work.
bash Tools/make-cert.sh || true
if ! codesign --force --sign "SideTab Local Signing" "$app" 2>/dev/null; then
  echo "Signing with the local certificate failed; using an ad-hoc signature (permission resets on every rebuild)."
  codesign --force --sign - "$app"
fi
echo "Built $app"

if [ "${1:-}" = "install" ]; then
  pkill -x SideTab 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/SideTab.app
  cp -R "$app" /Applications/
  # Forget permission granted to earlier builds, so macOS asks once for this one.
  if [ "${2:-}" = "reset-permission" ]; then
    tccutil reset ScreenCapture com.simoens.SideTab >/dev/null 2>&1 || true
  fi
  open /Applications/SideTab.app
  echo "Installed /Applications/SideTab.app"
fi
