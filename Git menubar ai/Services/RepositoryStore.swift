import Foundation

/// Persists the user's repository list so it survives relaunches.
struct RepositoryStore {
    private let defaultsKey = "repositories.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [Repository] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([Repository].self, from: data)
        } catch {
            // A corrupt list should not stop the app from launching.
            return []
        }
    }

    func save(_ repositories: [Repository]) {
        do {
            let data = try JSONEncoder().encode(repositories)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            assertionFailure("Failed to encode repositories: \(error)")
        }
    }
}
