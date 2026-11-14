import AppKit
import SwiftUI

/// Settings for the AI that writes commit messages (provider, API key, model)
/// and the optional Vercel token for the Deploys tab.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let maxHeight: CGFloat
    @State private var keyDraft = ""
    @State private var vercelTokenDraft = ""

    private var settings: CommitAISettingsModel { model.commitAI }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            FittedScrollView(maxHeight: maxHeight, estimatedHeight: 340) {
                VStack(alignment: .leading, spacing: 16) {
                    providerSection
                    if settings.provider.isCloud {
                        keySection(for: settings.provider)
                        if settings.status(for: settings.provider).isSaved {
                            modelSection(for: settings.provider)
                        }
                        privacyNote(for: settings.provider)
                    } else {
                        appleSection
                    }
                    descriptionToggle
                    Divider().opacity(0.5)
                    vercelSection
                }
                .padding(Theme.edge)
            }
        }
        .task { await settings.loadKeyStatus() }
        .task { await model.deployments.loadTokenStatus() }
        .onChange(of: settings.provider) { keyDraft = "" }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(systemImage: "chevron.left", help: "Back") {
                withAnimation(.snappy(duration: 0.2)) { model.isShowingSettings = false }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Settings")
                    .font(.system(size: 13, weight: .semibold))
                Text("Commit messages and Vercel")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 10)
    }

    // MARK: Provider

    private var providerSection: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Write commit messages with")
            SegmentedControl(
                items: CommitAIProvider.allCases,
                selection: $settings.provider,
                title: \.title
            )
        }
    }

    @ViewBuilder
    private var appleSection: some View {
        if let reason = CommitMessageGenerator.onDeviceUnavailableReason {
            InlineBanner(
                kind: .warning,
                title: "Apple Intelligence isn't available",
                detail: "\(reason) Until it is, messages are written by simple local rules. Pick OpenAI or Anthropic for better messages."
            )
        } else {
            Text("Runs on this Mac with Apple Intelligence, so your code never leaves your computer. It's a small model, so messages are basic. OpenAI and Anthropic write better ones.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: API key

    @ViewBuilder
    private func keySection(for provider: CommitAIProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "\(provider.title) API key") {
                if let url = provider.keysURL {
                    Link("Get a key", destination: url)
                        .font(.system(size: 11, weight: .medium))
                }
            }

            switch settings.status(for: provider) {
            case .saved(let suffix):
                savedKeyRow(for: provider, suffix: suffix)
            case .missing:
                keyEntry(for: provider)
            case .unknown:
                HStack { Spacer(); InlineSpinner(); Spacer() }
            }

            if let error = settings.errors[provider] {
                InlineBanner(kind: .error, title: "Something went wrong", detail: error) {
                    settings.errors[provider] = nil
                }
            }
        }
    }

    private func savedKeyRow(for provider: CommitAIProvider, suffix: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved in your keychain")
                    .font(.system(size: 12, weight: .medium))
                Text("Ends in …\(suffix)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if settings.isBusy(provider) {
                InlineSpinner()
            } else {
                Button("Remove") {
                    Task { await settings.removeKey(for: provider) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
                .help("Delete this key from your keychain")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card()
    }

    private func keyEntry(for provider: CommitAIProvider) -> some View {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                SecureField(provider.keyPlaceholder, text: $keyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { save(for: provider) }
                IconButton(systemImage: "doc.on.clipboard", help: "Paste from the clipboard") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        keyDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 3)
            .frame(height: 30)
            .card()

            WideButton(
                title: settings.isBusy(provider) ? "Checking key…" : "Save Key",
                systemImage: "key",
                style: .primary,
                isWorking: settings.isBusy(provider)
            ) {
                save(for: provider)
            }
            .disabled(trimmed.isEmpty || settings.isBusy(provider))
        }
    }

    private func save(for provider: CommitAIProvider) {
        let draft = keyDraft
        Task {
            if await settings.saveKey(draft, for: provider) {
                keyDraft = ""
            }
        }
    }

    // MARK: Model

    private func modelSection(for provider: CommitAIProvider) -> some View {
        let options = settings.modelOptions(for: provider)
        let selection = Binding<String>(
            get: { settings.selectedModel(for: provider) ?? "" },
            set: { settings.selectModel($0, for: provider) }
        )
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Model") {
                if settings.isBusy(provider) {
                    InlineSpinner()
                } else {
                    IconButton(systemImage: "arrow.clockwise", help: "Reload the list of models") {
                        Task { await settings.refreshModels(for: provider) }
                    }
                }
            }

            if options.isEmpty {
                Text("No models loaded yet. Press reload to fetch them from \(provider.title).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Model", selection: selection) {
                    if settings.selectedModel(for: provider) == nil {
                        Text("Choose a model").tag("")
                    }
                    ForEach(options) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func privacyNote(for provider: CommitAIProvider) -> some View {
        Text("When you press Generate, your changes are sent to \(provider.title). Files that look like secrets (.env, keys, certificates) are left out, and values that look like API keys are replaced with [redacted].")
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Description

    private var descriptionToggle: some View {
        @Bindable var settings = settings
        return Toggle(isOn: $settings.includeDescription) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a description")
                    .font(.system(size: 12, weight: .medium))
                Text("Bullet points under the title listing the main changes.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card()
    }

    // MARK: Vercel

    private var vercelSection: some View {
        let deployments = model.deployments
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Vercel token") {
                Link("Create a token", destination: URL(string: "https://vercel.com/account/settings/tokens")!)
                    .font(.system(size: 11, weight: .medium))
            }

            switch deployments.tokenStatus {
            case .saved(let suffix):
                savedVercelTokenRow(suffix: suffix)
            case .missing:
                vercelTokenEntry
            case .unknown:
                HStack { Spacer(); InlineSpinner(); Spacer() }
            }

            if let error = deployments.tokenError {
                InlineBanner(kind: .error, title: "Something went wrong", detail: error) {
                    deployments.tokenError = nil
                }
            }

            Text(vercelNote)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var vercelNote: String {
        if case .saved = model.deployments.tokenStatus {
            return "The Deploys tab uses this token to read your teams and deployments. Remove it to use your Vercel CLI login instead."
        }
        return VercelCredentials.hasCLILogin
            ? "Optional. The Deploys tab already uses your Vercel CLI login. A token here takes its place."
            : "The Deploys tab needs this token, or a Vercel CLI login (vercel login in Terminal), to read your deployments."
    }

    private func savedVercelTokenRow(suffix: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("Saved in your keychain")
                    .font(.system(size: 12, weight: .medium))
                Text("Ends in …\(suffix)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.deployments.isSavingToken {
                InlineSpinner()
            } else {
                Button("Remove") {
                    Task { await model.deployments.removeToken() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
                .help("Delete this token from your keychain")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .card()
    }

    private var vercelTokenEntry: some View {
        let trimmed = vercelTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSaving = model.deployments.isSavingToken
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                SecureField("Vercel access token", text: $vercelTokenDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(saveVercelToken)
                IconButton(systemImage: "doc.on.clipboard", help: "Paste from the clipboard") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        vercelTokenDraft = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 3)
            .frame(height: 30)
            .card()

            WideButton(
                title: isSaving ? "Checking token…" : "Save Token",
                systemImage: "key",
                style: .primary,
                isWorking: isSaving
            ) {
                saveVercelToken()
            }
            .disabled(trimmed.isEmpty || isSaving)
        }
    }

    private func saveVercelToken() {
        let draft = vercelTokenDraft
        Task {
            if await model.deployments.saveToken(draft) {
                vercelTokenDraft = ""
            }
        }
    }
}
