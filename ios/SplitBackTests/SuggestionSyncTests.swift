import XCTest
import SwiftData
@testable import SplitBackAPI

/// Cross-device sync of templates + decisions round-trips through the snapshot.
@MainActor
final class SuggestionSyncTests: XCTestCase {
    func testSnapshotRoundTrip() throws {
        let container = try SplitBackStore.makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(SplitTemplate(merchantKey: "rent", groupId: UUID(), category: "Rent",
                                     sharesJSON: SplitTemplate.encode(["me": 0.5, "alex": 0.5]),
                                     source: "explicit", displayName: "Rent"))
        context.insert(SuggestionDecision(key: "sub:netflix", decision: "dismissed"))
        try context.save()

        let data = try JSONEncoder().encode(try SuggestionSync.snapshot(context))
        let decoded = try JSONDecoder().decode(SuggestionSnapshot.self, from: data)

        // Wipe, then restore from the decoded snapshot (simulates a new device).
        for t in try context.fetch(FetchDescriptor<SplitTemplate>()) { context.delete(t) }
        for d in try context.fetch(FetchDescriptor<SuggestionDecision>()) { context.delete(d) }
        try context.save()
        try SuggestionSync.apply(decoded, context)

        let templates = try context.fetch(FetchDescriptor<SplitTemplate>())
        let decisions = try context.fetch(FetchDescriptor<SuggestionDecision>())
        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates.first?.merchantKey, "rent")
        XCTAssertEqual(templates.first?.source, "explicit")
        XCTAssertEqual(templates.first?.shares["me"] ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first?.key, "sub:netflix")
    }
}
