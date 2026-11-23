#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
git_sync_build=$(mktemp -d "${TMPDIR:-/tmp}/codebar-git-sync-tests.XXXXXX")
trap 'rm -rf "$git_sync_build"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$git_sync_build/ModuleCache" \
  "Git menubar ai/Models/GitStatus.swift" \
  "Git menubar ai/Models/GitSync.swift" \
  "Git menubar ai/Services/GitClient.swift" \
  "Git menubar ai/Services/GitFailure.swift" \
  "Git menubar ai/Services/GitSyncService.swift" \
  "Git menubar ai/Services/ProcessRunner.swift" \
  "Git menubar ai/Services/SensitiveFileScanner.swift" \
  Tests/GitSyncTests.swift -o "$git_sync_build/GitSyncTests"
"$git_sync_build/GitSyncTests"
