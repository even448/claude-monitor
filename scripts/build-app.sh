#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/ClaudeMonitor.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
mkdir -p "$ROOT/.build"

echo "==> Building ClaudeMonitor"
clang -O2 -mmacosx-version-min=12.0 -c "$ROOT/Sources/CStorageScanner/CStorageScanner.c" \
  -I "$ROOT/Sources/CStorageScanner/include" \
  -o "$ROOT/.build/CStorageScanner.o"
if [[ -n "${CLAUDE_MONITOR_SWIFT_SDK:-}" && -n "${CLAUDE_MONITOR_SWIFT_RESOURCE_DIR:-}" ]]; then
  # Development fallback for environments with a Command Line Tools SDK that
  # does not match the active Swift compiler.
  ARCH="$(uname -m)"
  swiftc \
    -sdk "$CLAUDE_MONITOR_SWIFT_SDK" \
    -resource-dir "$CLAUDE_MONITOR_SWIFT_RESOURCE_DIR" \
    -target "${ARCH}-apple-macosx12.0" \
    -module-cache-path "$ROOT/.build/module-cache" \
    -Xcc -fmodules-cache-path="$ROOT/.build/clang-module-cache" \
    -I "$ROOT/Sources/CStorageScanner/include" \
    "$ROOT/.build/CStorageScanner.o" \
    -O -whole-module-optimization \
    $(find Sources/ClaudeMonitor -name '*.swift' | sort) \
    -framework IOKit -framework UserNotifications \
    -o "$MACOS/ClaudeMonitor"
elif [[ -d "$ROOT/.toolchain/MacOSX.sdk" && -d "$ROOT/.toolchain/usr/lib/swift" ]]; then
  swiftc \
    -sdk "$ROOT/.toolchain/MacOSX.sdk" \
    -resource-dir "$ROOT/.toolchain/usr/lib/swift" \
    -target "$(uname -m)-apple-macosx12.0" \
    -module-cache-path "$ROOT/.build/module-cache" \
    -Xcc -fmodules-cache-path="$ROOT/.build/clang-module-cache" \
    -I "$ROOT/Sources/CStorageScanner/include" \
    "$ROOT/.build/CStorageScanner.o" \
    -O -whole-module-optimization \
    $(find Sources/ClaudeMonitor -name '*.swift' | sort) \
    -framework IOKit -framework UserNotifications \
    -o "$MACOS/ClaudeMonitor"
else
  swift build -c release --product ClaudeMonitor
  BIN="$(swift build -c release --show-bin-path)/ClaudeMonitor"
  cp "$BIN" "$MACOS/ClaudeMonitor"
fi

cp Resources/Info.plist "$CONTENTS/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$RESOURCES/AppIcon.icns"
fi

# Ad-hoc signing is enough for local use and makes TCC remember the identity.
codesign --force --deep --sign - "$APP" >/dev/null

echo "==> Built $APP"
echo "    open \"$APP\""
