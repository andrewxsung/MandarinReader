import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: auth.email ?? "—")
                    Button("Sign Out", role: .destructive) {
                        auth.signOut()
                        dismiss()
                    }
                }

                Section("About") {
                    Text("Stroke order data from Hanzi Writer / Make Me a Hanzi, derived from Arphic Technology fonts under the Arphic Public License (ARPHICPL.TXT is included in the app bundle).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AuthStore(storage: InMemoryTokenStorage(token: "preview", email: "a@x.com")))
}
