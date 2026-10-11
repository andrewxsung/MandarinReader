import Foundation

/// One-time removal of state left behind by the pre-accounts app.
enum LegacyCleanup {
    static let doneKey = "migration.accountsCleanupDone"

    /// - `settings.apiKey` / `settings.backendURL`: the old manual settings
    ///   screen stored the backend API key in plain UserDefaults.
    /// - `pendingReviews`: migration 003 restarts word ids, so reviews queued
    ///   by the old app could attach to unrelated new words.
    static let legacyKeys = ["settings.apiKey", "settings.backendURL", "pendingReviews"]

    static func run(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneKey) else { return }
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: doneKey)
    }
}
