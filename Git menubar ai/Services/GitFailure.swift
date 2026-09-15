import Foundation

/// A git invocation that failed, carried to the UI with the raw output intact.
nonisolated struct GitFailure: Error, Identifiable, Sendable, Equatable {
    let id: UUID
    /// The command as the user would type it, e.g. `git push`.
    let command: String
    let exitCode: Int32
    /// Cleaned up git output.
    let message: String

    init(id: UUID = UUID(), command: String, exitCode: Int32, message: String) {
        self.id = id
        self.command = command
        self.exitCode = exitCode
        self.message = message
    }

    /// A plain-language next step, derived from git's own wording.
    var hint: String? {
        let text = message.lowercased()

        if text.contains("xcrun") || text.contains("no developer tools")
            || text.contains("command line tools") {
            return "Install the Command Line Tools by running xcode-select --install in Terminal."
        }
        if text.contains("please tell me who you are") || text.contains("empty ident name") {
            return "Set your identity: git config --global user.name and user.email."
        }
        if text.contains("could not read username") || text.contains("authentication failed")
            || text.contains("permission denied (publickey)") || text.contains("batch mode")
            || text.contains("terminal prompts disabled") {
            return "Git needs credentials it can use without prompting. Open the repository in Terminal and push once to store them in the keychain or SSH agent."
        }
        if text.contains("non-fast-forward") || text.contains("fetch first")
            || (text.contains("rejected") && text.contains("behind")) {
            return "The remote has commits you don't have yet. Pull or rebase, then push again."
        }
        if text.contains("no upstream branch") {
            return "Publish the branch first so it has an upstream to push to."
        }
        if text.contains("nothing to commit") || text.contains("no changes added to commit") {
            return "There is nothing staged to commit."
        }
        if text.contains("unresolved conflict") || text.contains("fix conflicts") {
            return "Resolve the merge conflicts, then commit again."
        }
        if text.contains("index.lock") {
            return "Another Git process is running in this repository. Wait for it to finish."
        }
        if text.contains("not a git repository") {
            return "This folder is no longer a Git repository. Remove it and add it again."
        }
        if text.contains("hook") && text.contains("declined") {
            return "A Git hook rejected the commit."
        }
        return nil
    }

    /// Short headline for the error banner.
    var title: String {
        "\(command) failed"
    }
}
