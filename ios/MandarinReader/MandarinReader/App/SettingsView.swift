import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: auth.email ?? "—")
                    Button("Sign Out", role: .destructive) {
                        dismiss()
                        auth.signOut()
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        if deleting {
                            HStack { Text("Deleting Account…"); Spacer(); ProgressView() }
                        } else {
                            Text("Delete Account")
                        }
                    }
                    .disabled(deleting)
                }

                Section("About") {
                    Group {
                        Text("Stroke order data from Hanzi Writer / Make Me a Hanzi, derived from Arphic Technology fonts under the Arphic Public License (ARPHICPL.TXT is included in the app bundle).")
                        Text("Definitions and pinyin from CC-CEDICT (mdbg.net), licensed under Creative Commons Attribution-ShareAlike 4.0.")
                        Text("Starter HSK 1 word list adapted from complete-hsk-vocabulary by drkameleon (MIT License).")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Delete your account?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your account, your saved words, captured pages and review history. It can't be undone.")
            }
            .alert(
                "Couldn't delete your account",
                isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func deleteAccount() async {
        deleting = true
        defer { deleting = false }
        do {
            try await auth.deleteAccount()
            dismiss()
        } catch APIError.unauthorized {
            deleteError = "Your session has expired. Sign out, sign back in, and try again."
        } catch {
            deleteError = "Check your connection and try again."
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AuthStore(storage: InMemoryTokenStorage(token: "preview", email: "a@x.com")))
}
