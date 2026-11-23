import Foundation
import Observation

/// How repositories stay in step with commits made on other machines.
/// Stored in `UserDefaults`.
@Observable
final class SyncSettingsModel {
    /// How often every repository fetches in the background, even while the
    /// menu is closed.
    var fetchInterval: AutoFetchInterval {
        didSet { defaults.set(fetchInterval.rawValue, forKey: Keys.fetchInterval) }
    }

    /// Fast-forward a branch with no local commits as soon as a fetch finds new
    /// ones. Never runs when it could conflict with uncommitted work.
    var autoFastForward: Bool {
        didSet { defaults.set(autoFastForward, forKey: Keys.autoFastForward) }
    }

    /// How Pull and Sync combine remote commits with local ones.
    var pullStrategy: PullStrategy {
        didSet { defaults.set(pullStrategy.rawValue, forKey: Keys.pullStrategy) }
    }

    /// When a push is rejected because another machine pushed first, pull
    /// those commits in and push again.
    var pullBeforePush: Bool {
        didSet { defaults.set(pullBeforePush, forKey: Keys.pullBeforePush) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let fetchInterval = "sync.fetchInterval"
        static let autoFastForward = "sync.autoFastForward"
        static let pullStrategy = "sync.pullStrategy"
        static let pullBeforePush = "sync.pullBeforePush"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fetchInterval = (defaults.object(forKey: Keys.fetchInterval) as? Int)
            .flatMap(AutoFetchInterval.init(rawValue:)) ?? .oneMinute
        autoFastForward = defaults.object(forKey: Keys.autoFastForward) as? Bool ?? true
        pullStrategy = defaults.string(forKey: Keys.pullStrategy)
            .flatMap(PullStrategy.init(rawValue:)) ?? .rebase
        pullBeforePush = defaults.object(forKey: Keys.pullBeforePush) as? Bool ?? true
    }
}
