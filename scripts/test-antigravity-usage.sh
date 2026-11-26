#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/codebar-antigravity-tests.XXXXXX")
trap 'rm -rf "$test_build_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$test_build_dir/ModuleCache" \
  "Git menubar ai/Models/ClaudeAccountProfile.swift" \
  "Git menubar ai/Models/KiroAccountProfile.swift" \
  "Git menubar ai/Services/AIUsageService.swift" \
  "Git menubar ai/Services/ProcessRunner.swift" \
  Tests/AntigravityUsageTests.swift -o "$test_build_dir/AntigravityUsageTests"
"$test_build_dir/AntigravityUsageTests"
