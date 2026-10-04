import Foundation

enum AppConfig {
    /// Backend origin — the only place it appears.
    ///
    /// Debug builds target a locally running backend, which works from the
    /// Simulator (it shares the Mac's loopback). A physical device running a
    /// Debug build cannot reach `localhost`; point this at the Mac's LAN IP
    /// (e.g. `http://192.168.1.20:8000`) when testing on hardware.
    #if DEBUG
    static let baseURL = URL(string: "http://localhost:8000")!   // simulator → local backend
    #else
    static let baseURL = URL(string: "https://mandarinreader-production.up.railway.app")!
    #endif
}
