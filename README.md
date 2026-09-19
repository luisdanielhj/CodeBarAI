# CodeBarAI

A macOS menu bar app for developers who work with AI coding tools. It shows how much of your **Claude Code**, **Codex** and **Cursor** limits you have left, keeps an eye on your local Git repositories, and lets you commit and push without leaving the menu bar. It can also write the commit message for you with Apple's on-device model.

<p align="center">
  <img src="Git menubar ai/Assets.xcassets/AppIcon.appiconset/app-icon-256.png" width="128" alt="CodeBarAI icon">
</p>

## Features

### AI usage in the menu bar
- Shows the **percentage left** in each installed provider's main limits, right in the status item:
  - **Claude Code**: 5-hour session and 7-day weekly limits (plus the Sonnet and Opus weekly limits in the detail view)
  - **Codex**: primary (session) and secondary (weekly) windows
  - **Cursor**: Auto and API usage for the current billing cycle, plus the amount spent against your limit
- Finds installed tools on its own and refreshes usage in the background. It backs off after errors and follows `Retry-After` when a provider rate-limits it.
- Connect or disconnect each provider separately.
- If no provider is installed, the status item shows how many files have changed across your repositories.

### Git from the menu bar
- Add any local Git repository. It's watched with FSEvents, so status updates as soon as files change.
- Repositories with uncommitted changes are listed first. Each row shows the branch, ahead/behind counts and the number of changed files.
- **Commit** or **Commit & Push** in one click (`git add -A`, `git commit`, `git push`).
- **Publish** a branch that has no upstream yet (`git push --set-upstream`).
- Clear warnings for merge conflicts, a detached HEAD, a merge/rebase/cherry-pick in progress, or a branch with no remote.
- **Sensitive file check**: before committing, CodeBarAI warns you if `git add -A` would include files like `.env`, `id_rsa`, `*.pem`, `*.p12` or `credentials.json`, and asks you to confirm.

### Commit message generation
- Writes a [Conventional Commit](https://www.conventionalcommits.org/) subject line (`type(scope): summary`) from the changed files and a short excerpt of the diff.
- Uses **Apple Foundation Models** (Apple Intelligence) when it's available. Otherwise it falls back to a local heuristic based on file paths, branch names and diff stats.
- **Nothing leaves your Mac.** No commit message request goes to a third party.

### Jump into your tools
- Open a repository (or one changed file) in **Cursor**.
- Start a **Claude Code** session for the repository in a new Terminal window.
- Open the repository in the **Codex** desktop app.
- **Start Server**: finds a `dev`, `start` or `serve` script in `package.json`, works out the package manager (npm, pnpm, yarn or bun) from the `packageManager` field or the lockfile, installs dependencies if `node_modules` is missing, and runs the script in Terminal.
- Open the repository in Finder or Terminal.
- Shows each project's `favicon.ico` next to it in the list, when one exists.

## Requirements

- macOS 27 or later
- Xcode 27 or later (to build)
- Git, either at `/usr/bin/git` (Xcode Command Line Tools) or from Homebrew
- Optional: Claude Code, Codex and/or Cursor, signed in with a subscription
- Optional: Apple Intelligence turned on, for on-device commit messages

## Building from source

```bash
git clone https://github.com/luisdanielhj/CodeBarAI.git
cd CodeBarAI
open "Git menubar ai.xcodeproj"
```

1. In Xcode, select the **CodeBarAI** target and go to **Signing & Capabilities**.
2. Pick your own development team and change the bundle identifier to one you own. The project comes with a placeholder.
3. Choose the **CodeBarAI** scheme and press **⌘R**.

The app runs as a menu bar–only agent (`LSUIElement`), so it has no Dock icon. Look for it in the menu bar.

To build from the command line:

```bash
xcodebuild -project "Git menubar ai.xcodeproj" -scheme CodeBarAI -configuration Release build
```

## Permissions

CodeBarAI is **not sandboxed**, because it needs to run `git` and read your AI tools' local sign-in data. macOS may ask you for:

- **Automation (Terminal)**: to open a Terminal window and run `claude` or your dev server command in it.
- **Keychain access**: only if a tool stores its credentials in the Keychain. The app never opens a Keychain prompt by itself. If access is denied, it shows a message and you can allow access in Keychain Access.

## Privacy and how usage is read

The usage numbers come from your own subscription accounts, using the sign-in data each tool already keeps on your Mac:

| Provider    | Where credentials are read from                                                      | Sent to                                      |
|-------------|--------------------------------------------------------------------------------------|----------------------------------------------|
| Claude Code | `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`), then Keychain `Claude Code-credentials` | `api.anthropic.com/api/oauth/usage`          |
| Codex       | `~/.codex/auth.json` (or `$CODEX_HOME`), then Keychain `Codex Auth`                   | `chatgpt.com/backend-api/wham/usage`         |
| Cursor      | Cursor's local `state.vscdb` (read-only)                                              | `cursor.com/api/usage-summary`               |

- Each token is sent **only** to its own provider's usage endpoint. CodeBarAI never saves, logs or forwards it anywhere else.
- Requests use an ephemeral `URLSession` with no cookies and no cache. **Redirects are refused**, so a token can't be sent on to another host.
- A provider's credentials are only read when that provider is enabled. You can disconnect any provider from the usage view.
- Your repository list is kept in `UserDefaults`. There is no analytics or telemetry.

> **Note:** These usage endpoints are not public, documented APIs. Providers can change them without notice, and a provider may then show "unsupported usage response" until the app is updated. CodeBarAI is not affiliated with Anthropic, OpenAI or Cursor.

## Project structure

```
Git menubar ai/
├── MyApp.swift                    # App entry point, MenuBarExtra and status item rendering
├── Models/
│   ├── GitStatus.swift            # Status snapshot, file changes, commit/push blockers
│   └── Repository.swift
├── ViewModels/
│   ├── AppModel.swift             # Repository list, refresh scheduling, git actions
│   ├── RepositoryState.swift      # Per-repository observable UI state
│   └── AIUsageModel.swift         # Provider enablement and usage refresh loop
├── Services/
│   ├── GitClient.swift            # Runs git non-interactively (no prompts, BatchMode SSH)
│   ├── ProcessRunner.swift        # Async Process wrapper with timeouts
│   ├── FileSystemWatcher.swift    # FSEvents watcher that ignores routine .git noise
│   ├── AIUsageService.swift       # Reads credentials and fetches/parses provider usage
│   ├── CommitMessageGenerator.swift   # Foundation Models guided generation
│   ├── CommitMessageHeuristic.swift   # Local fallback message builder
│   ├── SensitiveFileScanner.swift # Name-based secret detection before commit
│   ├── DevServer.swift            # package.json script and package manager detection
│   ├── SystemIntegration.swift    # Finder, Terminal, Cursor, Claude Code, Codex
│   ├── ProjectIconLoader.swift    # Finds a project's favicon.ico, with limits
│   ├── RepositoryStore.swift      # Saves the repository list
│   └── GitFailure.swift           # Readable git errors and hints
└── Views/                         # SwiftUI views for the menu bar window
```

Built with SwiftUI and the Observation framework, using Swift concurrency throughout. There are no third-party dependencies.

## Contributing

Issues and pull requests are welcome. Before opening a PR:

- Keep the app dependency-free unless there's a strong reason not to.
- Follow the existing style: small focused types, doc comments that explain *why*, and `nonisolated`/`Sendable` value types for anything that crosses actors.
- If you change credential handling or network requests, describe the privacy impact in the PR.
- Test with at least one real repository, including a failure case (no upstream, conflicts, detached HEAD).

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 Daniel Juarez.
