import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where a generated message came from, so the UI can be honest about it.
nonisolated enum CommitMessageSource: Sendable, Equatable {
    case foundationModels
    /// The local fallback, with the reason the on-device model was skipped.
    case heuristic(reason: String?)

    var label: String {
        switch self {
        case .foundationModels: return "On-device model"
        case .heuristic: return "Local fallback"
        }
    }
}

nonisolated struct GeneratedCommitMessage: Sendable {
    var message: String
    var source: CommitMessageSource
}

#if canImport(FoundationModels)

/// The conventional commit types the model may choose from.
@Generable
nonisolated enum ConventionalCommitType: String, Codable, Sendable {
    case feat
    case fix
    case docs
    case style
    case refactor
    case perf
    case test
    case build
    case ci
    case chore
}

/// Guided-generation shape for a commit subject line.
@Generable
nonisolated struct ConventionalCommitDraft: Sendable {
    @Guide(description: "The conventional commit type that best describes the change")
    var type: ConventionalCommitType

    @Guide(description: "A short lowercase scope such as a module or folder name, or an empty string when no single scope fits")
    var scope: String

    @Guide(description: "Imperative, lowercase summary of the change under 60 characters, with no trailing period")
    var summary: String
}

#endif

/// Generates a short Conventional Commit message from the current Git changes.
///
/// Prefers Apple's on-device Foundation Models and falls back to a filename and
/// diff-summary heuristic. Nothing leaves the machine either way.
struct CommitMessageGenerator {

    /// A short description of what will be used, shown next to the generate button.
    var engineDescription: String {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return "On-device model"
        case .unavailable:
            return "Local fallback"
        }
        #else
        return "Local fallback"
        #endif
    }

    func generate(for context: DiffContext) async -> GeneratedCommitMessage {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            do {
                let message = try await generateOnDevice(for: context)
                return GeneratedCommitMessage(message: message, source: .foundationModels)
            } catch {
                return fallback(for: context, reason: error.localizedDescription)
            }
        case .unavailable(let reason):
            return fallback(for: context, reason: Self.describe(reason))
        }
        #else
        return fallback(for: context, reason: "This build has no Foundation Models support.")
        #endif
    }

    private func fallback(for context: DiffContext, reason: String?) -> GeneratedCommitMessage {
        GeneratedCommitMessage(
            message: CommitMessageHeuristic.message(for: context),
            source: .heuristic(reason: reason)
        )
    }

    // MARK: - Foundation Models

    #if canImport(FoundationModels)

    private func generateOnDevice(for context: DiffContext) async throws -> String {
        let session = LanguageModelSession {
            """
            You write Conventional Commit subject lines from a summary of a developer's \
            Git changes.
            Describe what the change accomplishes, not how many files moved.
            The summary must be imperative mood, lowercase, and under 60 characters, \
            with no trailing period.
            Leave the scope empty unless one module or folder clearly covers the change.
            """
        }

        let response = try await session.respond(
            to: Self.prompt(for: context),
            generating: ConventionalCommitDraft.self,
            // Greedy sampling keeps the same change set producing the same message.
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 200)
        )

        guard let message = Self.format(response.content) else {
            throw CommitGenerationError.unusableResponse
        }
        return message
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is turned off in System Settings."
        case .modelNotReady:
            return "The on-device model is still downloading."
        @unknown default:
            return "The on-device model is unavailable."
        }
    }

    /// Turns a draft into a validated `type(scope): summary` line.
    private static func format(_ draft: ConventionalCommitDraft) -> String? {
        var summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)

        // The model occasionally answers with a whole conventional line in the
        // summary field; drop the duplicated prefix.
        if let colon = summary.firstIndex(of: ":") {
            let candidate = summary[summary.startIndex..<colon]
            let looksLikeAPrefix = candidate.count <= 24
                && candidate.allSatisfy { $0.isLetter || "()-_".contains($0) }
            if looksLikeAPrefix {
                summary = String(summary[summary.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        // Keep only the first line and strip trailing punctuation.
        summary = summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? summary
        while let last = summary.last, last == "." || last == " " {
            summary.removeLast()
        }
        guard !summary.isEmpty else { return nil }
        summary = summary.prefix(1).lowercased() + summary.dropFirst()

        var prefix = draft.type.rawValue
        if let scope = CommitMessageHeuristic.sanitize(scope: draft.scope) {
            prefix += "(\(scope))"
        }
        return CommitMessageHeuristic.truncate("\(prefix): \(summary)", to: 72)
    }

    /// Compact description of the change set. Kept small to stay inside the context window.
    private static func prompt(for context: DiffContext) -> String {
        var lines: [String] = []
        if let branch = context.branch {
            lines.append("Branch: \(branch)")
        }

        lines.append("Changed files:")
        let listed = context.changes.prefix(40)
        for change in listed {
            var line = "- \(change.kind.label.lowercased()) \(change.path)"
            if let stat = context.stats.first(where: { $0.path == change.path }) {
                line += " (+\(stat.insertions)/-\(stat.deletions))"
            }
            lines.append(line)
        }
        if context.changes.count > listed.count {
            lines.append("- and \(context.changes.count - listed.count) more files")
        }

        if !context.patchExcerpt.isEmpty {
            lines.append("")
            lines.append("Diff excerpt:")
            lines.append(context.patchExcerpt)
        }

        return lines.joined(separator: "\n")
    }

    #endif
}

nonisolated enum CommitGenerationError: LocalizedError {
    case unusableResponse

    var errorDescription: String? {
        switch self {
        case .unusableResponse:
            return "The model did not return a usable commit message."
        }
    }
}
