import SwiftUI

@main
struct MandarinReaderApp: App {

    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            StartSessionView()
                .environmentObject(settings)
        }
    }
}
