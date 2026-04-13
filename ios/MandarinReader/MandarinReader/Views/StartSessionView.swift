import SwiftUI

struct StartSessionView: View {

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var session = SessionViewModel()

    @State private var wordCount: Int = 20
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var showPractice: Bool = false
    @State private var showSettings: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                Text("MandarinReader")
                    .font(.system(size: 48, weight: .bold))
                Text("Handwriting Practice")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Spacer()

                VStack(spacing: 16) {
                    Stepper(value: $wordCount, in: 5...50, step: 5) {
                        Text("Words this session: **\(wordCount)**")
                            .font(.title3)
                    }
                    .padding(.horizontal, 64)

                    Button(action: startSession) {
                        HStack {
                            if isLoading {
                                ProgressView().tint(.white)
                            }
                            Text(isLoading ? "Loading…" : "Start Practice")
                                .font(.title3.weight(.semibold))
                        }
                        .frame(maxWidth: 320)
                        .padding()
                        .background(settings.isConfigured ? Color.accentColor : Color.gray)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!settings.isConfigured || isLoading)

                    if !settings.isConfigured {
                        Text("Configure backend URL and API key in Settings first")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .navigationDestination(isPresented: $showPractice) {
                PracticeView(session: session)
            }
        }
    }

    private func startSession() {
        guard let client = settings.makeAPIClient() else {
            errorMessage = "Invalid backend URL"
            return
        }
        errorMessage = nil
        isLoading = true
        Task {
            do {
                let words = try await client.fetchQueue(count: wordCount)
                await MainActor.run {
                    session.start(words: words)
                    isLoading = false
                    if words.isEmpty {
                        errorMessage = "Queue is empty — add words via the browser extension first"
                    } else {
                        showPractice = true
                    }
                }
            } catch APIError.unauthorized {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Invalid API key"
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = "Failed to load queue: \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    StartSessionView()
        .environmentObject(AppSettings())
}
