import SwiftUI

/// Overall who-owes-whom across all groups (`GET /balances`). Net > 0 = the household owes them.
struct BalancesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var balances: [Balance] = []
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List(balances) { entry in
                HStack {
                    Text(entry.displayName ?? entry.identifier)
                    Spacer()
                    Text(entry.net.formatted(.currency(code: "USD")))
                        .foregroundStyle(entry.net >= 0 ? .green : .red)
                }
            }
            .overlay {
                if balances.isEmpty {
                    ContentUnavailableView("No Balances", systemImage: "scalemass",
                                           description: Text("Add expenses with splits to see balances."))
                }
            }
            .navigationTitle("Balances")
            .refreshable { await load() }
            .task { await load() }
            .errorAlert($errorText)
        }
    }

    private func load() async {
        do { balances = try await env.balances.overall() }
        catch { errorText = errorMessage(error) }
    }
}
