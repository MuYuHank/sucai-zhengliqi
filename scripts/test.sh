#!/usr/bin/env bash
# 运行全部测试。
# 只装了 Command Line Tools（没有 Xcode）的 Mac 上没有 XCTest，
# 测试会通过 Tests/OrganizerCoreTests/XCTestShim.swift 跑在 Swift Testing 上。
# Command Line Tools 里的 Testing.framework 不在默认搜索路径中，这里补上。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXTRA=()
if [[ "$(uname -s)" == "Darwin" ]]; then
  DEV="$(xcode-select -p 2>/dev/null || true)"
  FW="${DEV}/Library/Developer/Frameworks"
  LIB="${DEV}/Library/Developer/usr/lib"
  if [[ "${DEV}" == *CommandLineTools* && -d "${FW}/Testing.framework" ]]; then
    EXTRA=(-Xswiftc -F -Xswiftc "${FW}" -Xlinker -F -Xlinker "${FW}" -Xlinker -rpath -Xlinker "${FW}" -Xlinker -rpath -Xlinker "${LIB}")
  fi
fi

if [[ ${#EXTRA[@]} -gt 0 ]]; then
  swift test "${EXTRA[@]}" "$@"
else
  swift test "$@"
fi
