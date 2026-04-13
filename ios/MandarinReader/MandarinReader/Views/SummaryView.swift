import SwiftUI

struct SummaryView: View {
    @ObservedObject var session: SessionViewModel
    var body: some View {
        Text("Summary (Task 10) — \(session.pendingReviews.count) reviews")
    }
}
