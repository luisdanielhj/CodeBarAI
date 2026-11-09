import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where a generated message came from, so the UI can be honest about it.
nonisolated enum CommitMessageSource: Sendable, Equatable {
    case foundationModels
    case cloud(provider: CommitAIProvider, model: String)
    /// The local fallback, with the reason the on-device model was skipped.
    case heuristic(reason: String?)

    var label: String {
        switch self {
        case .foundationModels: return "On-device model"
        case .cloud(let provider, let model): return "\(model) (\(provider.title))"
        case .heuristic: return "Local fallback"
        }
    }
}

nonisolated struct GeneratedCommitMessage: Sendable {
    var message: String
    var source: CommitMessageSource
    /// Files whose diff was shortened to fit the model's input.
    var shortenedFiles: Int = 0

    /// One line under the editor saying who wrote the message.
    var note: String {
        var note: String
        switch source {
        case .foundationModels:
            note = "Written on this Mac by Apple Intelligence."
        case .cloud(let provider, let model):
            note = "Written by \(model) (\(provider.title))."
        case .heuristic(let reason):
            note = "Written by simple local rules" + (reason.map { ": \($0)" } ?? ".")
        }
        if shortenedFiles > 0 {
            note += " Diffs of \(shortenedFiles) \(shortenedFiles == 1 ? "file were" : "files were") shortened to fit."
        }
        return note
    }
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
    @Guide(description: "The conventional commit type for the most important change")
    var type: ConventionalCommitType

    @Guide(description: "One short lowercase word for the area of code, or an empty string when the changes span several areas")
    var scope: String

    @Guide(description: "Imperative, lowercase summary of the whole change under 60 characters, with no trailing period")
    var summary: String
}

/// Subject line plus bullet points.
@Generable
nonisolated struct DetailedCommitDraft: Sendable {
    @Guide(description: "The conventional commit type for the most important change")
    var type: ConventionalCommitType

    @Guide(description: "One short lowercase word for the area of code, or an empty string when the changes span several areas")
    var scope: String

    @Guide(description: "Imperative, lowercase summary of the whole change under 60 characters, with no trailing period")
    var summary: String

    @Guide(
        description: "Two to five bullet points, one per distinct change, most important first. Each starts with an imperative verb, is under 90 characters, and has no leading dash.",
        .maximumCount(5)
    )
    var details: [String]
}

#endif

/// Writes a Conventional Commit message from the current Git changes, using
/// whichever AI the user picked in Settings.
///
/// Apple's on-device model is the default and falls back to a filename
/// heuristic when it is unavailable; nothing leaves the machine on that path.
/// OpenAI and Anthropic receive the prepared diff over HTTPS.
struct CommitMessageGenerator {
    /// The on-device model's context window is about 4,096 tokens, shared by
    /// the instructions, the prompt and the answer.
    private static let onDeviceBudget = 7_000
    private static let onDeviceRetryBudget = 3_000
    /// Cloud models read far more; this keeps a request to roughly 25k tokens.
    private static let cloudBudget = 100_000

    func generate(
        for context: DiffContext,
        configuration: CommitAIConfiguration
    ) async throws -> GeneratedCommitMessage {
        switch configuration.provider {
        case .apple:
            return await generateOnDevice(for: context, includeDescription: configuration.includeDescription)
        case .openAI, .anthropic:
            return try await generateInCloud(for: context, configuration: configuration)
        }
    }

    // MARK: - Cloud

    private func generateInCloud(
        for context: DiffContext,
        configuration: CommitAIConfiguration
    ) async throws -> GeneratedCommitMessage {
        let provider = configuration.provider
        guard let apiKey = configuration.apiKey, !apiKey.isEmpty else {
            throw CloudModelError.missingKey(provider)
        }
        guard let model = configuration.model, !model.isEmpty else {
            throw CloudModelError.missingModel(provider)
        }

        let prompt = CommitPromptBuilder.prompt(for: context, characterBudget: Self.cloudBudget, maxListedFiles: 300)
        let reply = try await CloudModelClient.complete(
            provider: provider,
            model: model,
            apiKey: apiKey,
            instructions: Self.cloudInstructions(includeDescription: configuration.includeDescription),
            prompt: prompt.text
        )
        guard let message = Self.clean(reply, includeDescription: configuration.includeDescription) else {
            throw CloudModelError.emptyResponse(provider)
        }
        return GeneratedCommitMessage(
            message: message,
            source: .cloud(provider: provider, model: model),
            shortenedFiles: prompt.shortenedFiles
        )
    }

    nonisolated static func cloudInstructions(includeDescription: Bool) -> String {
        var rules = """
        You write Git commit messages in the Conventional Commits format from a developer's changes.

        Read every file in the change summary and describe the change set as a whole, not just the first files.

        First line: type(scope): summary
        - type is one of: feat (new capability), fix (bug fix), refactor (restructure without changing behavior), \
        perf, docs, style, test, build, ci, chore. Pick the type of the most important change; if a feature \
        comes with fixes, use feat.
        - scope is optional. Use one short lowercase word for the area of code only when one area covers the \
        change; otherwise write type: summary.
        - summary is imperative, lowercase, with no trailing period. Keep the whole line under 72 characters.
        - Say what changed for the user or the code. Never write "update files", "various changes" or file counts.
        """
        if includeDescription {
            rules += """


            Then a blank line and 2 to 6 bullet points, each starting with "- ".
            - One bullet per distinct change, most important first. Together they must cover every significant \
            change in the summary, including new files.
            - Start each bullet with an imperative verb and keep it under 90 characters.
            - Group small related edits into one bullet. Don't list files one by one.
            """
        } else {
            rules += "\n\nWrite only the first line."
        }
        rules += """


        Only describe changes that appear in the diffs. Don't guess at reasons that aren't visible.
        Reply with the commit message only: no code fences, quotes or commentary.
        """
        if includeDescription {
            rules += """


            Example:
            feat(settings): let users pick the AI that writes commit messages

            - Add a settings screen with Apple, OpenAI and Anthropic options
            - Store API keys in the macOS keychain instead of preferences
            - Send every changed file to the model, not just the first ones
            """
        }
        return rules
    }

    /// Tidies a cloud model's reply: drops code fences, labels and quotes, and
    /// normalizes bullets.
    nonisolated static func clean(_ reply: String, includeDescription: Bool) -> String? {
        var lines = reply
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        lines.removeAll { $0.hasPrefix("```") }
        while let first = lines.first,
              first.isEmpty || (first.lowercased().hasPrefix("commit message") && first.hasSuffix(":")) {
            lines.removeFirst()
        }

        guard var subject = lines.first else { return nil }
        subject = subject.replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`").union(.whitespaces))
        while subject.hasSuffix(".") { subject.removeLast() }
        guard !subject.isEmpty else { return nil }
        guard includeDescription else { return subject }

        var body: [String] = []
        for line in lines.dropFirst() {
            var line = line
            for marker in ["* ", "• ", "– "] where line.hasPrefix(marker) {
                line = "- " + line.dropFirst(marker.count)
            }
            if line.isEmpty, body.last?.isEmpty ?? true { continue }
            body.append(line)
        }
        while body.last?.isEmpty == true { body.removeLast() }
        return body.isEmpty ? subject : subject + "\n\n" + body.joined(separator: "\n")
    }

    // MARK: - On device

    /// `nil` when the on-device model can be used, otherwise why not.
    static var onDeviceUnavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason): return describe(reason)
        }
        #else
        return "This build has no Foundation Models support."
        #endif
    }

    private func generateOnDevice(for context: DiffContext, includeDescription: Bool) async -> GeneratedCommitMessage {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            do {
                return try await respondOnDevice(context, includeDescription: includeDescription, budget: Self.onDeviceBudget)
            } catch LanguageModelError.contextSizeExceeded {
                do {
                    return try await respondOnDevice(context, includeDescription: includeDescription, budget: Self.onDeviceRetryBudget)
                } catch {
                    return fallback(for: context, reason: error.localizedDescription)
                }
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

    #if canImport(FoundationModels)

    private func respondOnDevice(
        _ context: DiffContext,
        includeDescription: Bool,
        budget: Int
    ) async throws -> GeneratedCommitMessage {
        let prompt = CommitPromptBuilder.prompt(for: context, characterBudget: budget, maxListedFiles: 40)
        let session = LanguageModelSession {
            """
            You write Conventional Commit messages from a summary of a developer's Git changes.
            Read every file in the summary and describe the change set as a whole.
            Use feat for new capabilities, fix for bug fixes, refactor for restructuring without behavior \
            changes, and docs, test, build, ci, style, perf or chore when only those apply.
            Say what changed for the user or the code. Never write "update files" or count files.
            Only describe changes that appear in the summary.
            """
        }
        // Greedy sampling keeps the same change set producing the same message.
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: includeDescription ? 400 : 200)

        let message: String?
        if includeDescription {
            let response = try await session.respond(to: prompt.text, generating: DetailedCommitDraft.self, options: options)
            let draft = response.content
            message = Self.format(type: draft.type, scope: draft.scope, summary: draft.summary).map { subject in
                let bullets = Self.bullets(from: draft.details)
                return bullets.isEmpty ? subject : subject + "\n\n" + bullets.joined(separator: "\n")
            }
        } else {
            let response = try await session.respond(to: prompt.text, generating: ConventionalCommitDraft.self, options: options)
            let draft = response.content
            message = Self.format(type: draft.type, scope: draft.scope, summary: draft.summary)
        }

        guard let message else { throw CommitGenerationError.unusableResponse }
        return GeneratedCommitMessage(message: message, source: .foundationModels, shortenedFiles: prompt.shortenedFiles)
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
    private static func format(type: ConventionalCommitType, scope: String, summary: String) -> String? {
        var summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

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

        var prefix = type.rawValue
        if let scope = CommitMessageHeuristic.sanitize(scope: scope) {
            prefix += "(\(scope))"
        }
        return CommitMessageHeuristic.truncate("\(prefix): \(summary)", to: 72)
    }

    #endif

    /// `- Item` lines from the model's detail strings, without duplicates.
    nonisolated static func bullets(from details: [String]) -> [String] {
        var seen = Set<String>()
        return details.compactMap { detail in
            var text = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = text.first, "-*•".contains(first) {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            while text.hasSuffix(".") { text.removeLast() }
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { return nil }
            return "- " + text.prefix(1).uppercased() + text.dropFirst()
        }
    }
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
