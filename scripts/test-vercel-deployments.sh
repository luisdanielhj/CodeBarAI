#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir=$(mktemp -d "${TMPDIR:-/tmp}/codebar-vercel-tests.XXXXXX")
trap 'rm -rf "$test_build_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$test_build_dir/ModuleCache" \
  "Git menubar ai/Models/VercelDeployment.swift" \
  Tests/VercelDeploymentsTests.swift -o "$test_build_dir/VercelDeploymentsTests"
"$test_build_dir/VercelDeploymentsTests"
