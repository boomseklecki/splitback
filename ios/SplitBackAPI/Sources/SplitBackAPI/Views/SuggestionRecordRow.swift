import SwiftUI

/// One record (an expense or transaction) shown in an Inbox confirmation sheet: title + amount on top, with
/// the date and optional category beneath. Shared by the Link and Categorize confirm sheets so they read
/// consistently.
struct SuggestionRecordRow: View {
    let title: String
    let amount: Decimal
    let currency: String
    let date: Date
    var category: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline).lineLimit(2)
                Spacer()
                Text(amount.formatted(.currency(code: currency))).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                if let category { Text("· \(category)") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}
