import SwiftUI

struct SummaryView: View {

    @ObservedObject var session: SessionViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    enum SyncState: Equatable {
        case pending
        case syncing
        case succeeded
        case failed(String)
    }

    @State private var syncState: SyncState = .pending

    private var knownCount: Int { session.pendingReviews.filter { $0.result == .known }.count }
    private var learningCount: Int { session.pendingReviews.filter { $0.result == .learning }.count }

    var body: some View {
        VStack(spacing: 24) {
            Text("Session Complete")
                .font(.largeTitle.bold())

            HStack(spacing: 32) {
                stat(value: "\(knownCount)", label: "Known", color: .green)
                stat(value: "\(learningCount)", label: "To practice", color: .orange)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(session.pendingReviews.enumerated()), id: \.offset) { _, review in
                        reviewRow(review)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 300)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            syncSection

            Spacer()
        }
        .padding()
        .navigationBarBackButtonHidden(true)
    }

    @ViewBuilder
    private func stat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 60, weight: .bold)).foregroundStyle(color)
            Text(label).font(.body).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func reviewRow(_ review: PendingReview) -> some View {
        HStack(spacing: 12) {
            Image(systemName: review.result == .known ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(review.result == .known ? .green : .orange)
            Text(review.traditional)
                .font(.title2)
                .foregroundStyle(.primary)
            if let pinyin = review.pinyin, !pinyin.isEmpty {
                Text(pinyin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(review.result.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var syncSection: some View {
        switch syncState {
        case .pending:
            Button(action: sync) {
                Text("Sync Results")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: 320)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        case .syncing:
            HStack {
                ProgressView()
                Text("Syncing…")
            }
            .padding()
        case .succeeded:
            VStack(spacing: 12) {
                Label("Results synced", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("New Session") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Discard & Exit") {
                        session.clearPersistedReviews()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    Button("Retry") { sync() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func sync() {
        guard let client = settings.makeAPIClient() else {
            syncState = .failed("Backend not configured")
            return
        }
        syncState = .syncing
        let reviews = session.pendingReviews
        Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for review in reviews {
                        group.addTask {
                            try await client.submitReview(wordId: review.wordId, result: review.result)
                        }
                    }
                    try await group.waitForAll()
                }
                await MainActor.run {
                    session.clearPersistedReviews()
                    syncState = .succeeded
                }
            } catch {
                await MainActor.run {
                    syncState = .failed("Sync failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

#Preview {
    let session = SessionViewModel()
    session.start(words: [
        WordQueueItem(id: 1, traditional: "記", pinyin: nil, definition: nil,
                      priorityScore: 1, encounterCount: 1, contextSentence: nil),
        WordQueueItem(id: 2, traditional: "住", pinyin: nil, definition: nil,
                      priorityScore: 1, encounterCount: 1, contextSentence: nil)
    ])
    session.skip()
    session.skip()
    return SummaryView(session: session)
        .environmentObject(AppSettings())
}
