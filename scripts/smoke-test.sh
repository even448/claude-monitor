#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p build/tests .build
SWIFT_ARGS=()
clang -O2 -mmacosx-version-min=12.0 -c Sources/CStorageScanner/CStorageScanner.c \
  -I Sources/CStorageScanner/include -o .build/CStorageScanner.o
if [[ -n "${CLAUDE_MONITOR_SWIFT_SDK:-}" && -n "${CLAUDE_MONITOR_SWIFT_RESOURCE_DIR:-}" ]]; then
  SWIFT_ARGS=(
    -sdk "$CLAUDE_MONITOR_SWIFT_SDK"
    -resource-dir "$CLAUDE_MONITOR_SWIFT_RESOURCE_DIR"
    -module-cache-path "$ROOT/.build/test-module-cache"
    -Xcc -fmodules-cache-path="$ROOT/.build/test-clang-cache"
  )
elif [[ -d "$ROOT/.toolchain/MacOSX.sdk" && -d "$ROOT/.toolchain/usr/lib/swift" ]]; then
  SWIFT_ARGS=(
    -sdk "$ROOT/.toolchain/MacOSX.sdk"
    -resource-dir "$ROOT/.toolchain/usr/lib/swift"
    -module-cache-path "$ROOT/.build/test-module-cache"
    -Xcc -fmodules-cache-path="$ROOT/.build/test-clang-cache"
  )
fi
compile() {
  if [[ ${#SWIFT_ARGS[@]} -gt 0 ]]; then
    swiftc "${SWIFT_ARGS[@]}" "$@"
  else
    swiftc "$@"
  fi
}

compile \
  -I Sources/CStorageScanner/include \
  .build/CStorageScanner.o \
  Sources/ClaudeMonitor/Support/Formatters.swift \
  Sources/ClaudeMonitor/Support/Models.swift \
  Sources/ClaudeMonitor/Storage/CStorageScanBridge.swift \
  Sources/ClaudeMonitor/Storage/StorageScanner.swift \
  Tests/StorageScannerSmoke.swift \
  -o build/tests/StorageScannerSmoke
./build/tests/StorageScannerSmoke

compile \
  Sources/ClaudeMonitor/Support/Formatters.swift \
  Sources/ClaudeMonitor/Support/Models.swift \
  Sources/ClaudeMonitor/Storage/IndexScanner.swift \
  Tests/IndexScannerSmoke.swift \
  -o build/tests/IndexScannerSmoke
./build/tests/IndexScannerSmoke
