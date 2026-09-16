import Foundation

/// Persists the user's repository list so it survives relaunches.
struct RepositoryStore {
    private let defaultsKey = "repositories.v1"
    private let defaults: UserDefaults
    private let legacyDefaults: [UserDefaults]

    init(defaults: UserDefaults = .standard, legacyDefaults: [UserDefaults]? = nil) {
        self.defaults = defaults
        self.legacyDefaults = legacyDefaults ?? Self.legacyDefaultsForCurrentApp()
    }

    func load() -> [Repository] {
        let current = decode(from: defaults)
        let candidates = current + legacyDefaults.flatMap(decode(from:))
        var seenPaths = Set<String>()
        var merged: [Repository] = []

        for repository in candidates {
            let canonicalPath = repository.canonicalPath
            guard seenPaths.insert(canonicalPath).inserted else { continue }
            merged.append(Repository(id: repository.id, path: canonicalPath))
        }

        // The target originally shipped as "MyApp". Xcode included the product
        // name in its generated bundle identifier, so renaming the target made
        // UserDefaults look empty. Persist the merged list in the current domain.
        if merged != current {
            save(merged)
        }

        return merged
    }

    func save(_ repositories: [Repository]) {
        do {
            let data = try JSONEncoder().encode(repositories)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            assertionFailure("Failed to encode repositories: \(error)")
        }
    }

    private func decode(from defaults: UserDefaults) -> [Repository] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([Repository].self, from: data)
        } catch {
            // A corrupt list should not stop the app from launching or prevent a
            // valid list in another preference domain from being recovered.
            return []
        }
    }

    private static func legacyDefaultsForCurrentApp() -> [UserDefaults] {
        guard
            let identifier = Bundle.main.bundleIdentifier,
            let separator = identifier.lastIndex(of: ".")
        else { return [] }

        let legacyIdentifier = identifier[..<separator] + ".MyApp"
        guard legacyIdentifier != identifier,
              let defaults = UserDefaults(suiteName: String(legacyIdentifier))
        else { return [] }
        return [defaults]
    }
}
