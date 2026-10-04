import SwiftUI

@main
struct MandarinReaderApp: App {

    @StateObject private var auth = AuthStore()

    var body: some Scene {
        WindowGroup {
            if auth.isSignedIn {
                StartSessionView()
                    .environmentObject(auth)
            } else {
                LoginView()
                    .environmentObject(auth)
            }
        }
    }
}
