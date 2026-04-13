import Foundation
import Combine

/// Backend URL and API key, persisted to UserDefaults.
/// Published so SwiftUI views refresh when values change.
final class AppSettings: ObservableObject {

    private enum Key {
        static let backendURL = "settings.backendURL"
        static let apiKey = "settings.apiKey"
    }

    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    @Published var backendURL: String = ""
    @Published var apiKey: String = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load from UserDefaults
        self.backendURL = defaults.string(forKey: Key.backendURL) ?? ""
        self.apiKey = defaults.string(forKey: Key.apiKey) ?? ""

        // Set up publishers to persist changes
        self.$backendURL
            .dropFirst()
            .sink { [defaults] value in
                defaults.set(value, forKey: Key.backendURL)
            }
            .store(in: &cancellables)

        self.$apiKey
            .dropFirst()
            .sink { [defaults] value in
                defaults.set(value, forKey: Key.apiKey)
            }
            .store(in: &cancellables)
    }

    var isConfigured: Bool {
        !backendURL.isEmpty && !apiKey.isEmpty
    }

    /// Convenience for wiring APIClient. Nil if `backendURL` is invalid.
    func makeAPIClient() -> APIClient? {
        guard let url = URL(string: backendURL), !apiKey.isEmpty else { return nil }
        return APIClient(baseURL: url, apiKey: apiKey)
    }
}
