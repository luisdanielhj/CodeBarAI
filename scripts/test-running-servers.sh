#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
server_test_node=$(command -v node)
server_test_npm=$(command -v npm)
server_test_build=$(mktemp -d "${TMPDIR:-/tmp}/codebar-server-tests.XXXXXX")
trap 'rm -rf "$server_test_build"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$server_test_build/ModuleCache" \
  "Git menubar ai/Models/Repository.swift" \
  "Git menubar ai/Models/RunningServer.swift" \
  "Git menubar ai/Services/RunningServerService.swift" \
  "Git menubar ai/ViewModels/RunningServersModel.swift" \
  Tests/RunningServersTests.swift -o "$server_test_build/RunningServersTests"
"$server_test_build/RunningServersTests" "$server_test_node" "$server_test_npm"
