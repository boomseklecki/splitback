import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Maps raw Plaid category labels to canonical categories using Apple's on-device Foundation Models
/// (Apple Intelligence). Nothing leaves the device; unavailable hardware/OS makes this a no-op and the
/// manual category picker remains the path.
enum CategoryMapper {
    /// Whether the on-device model is usable right now (capable device, model downloaded, AI enabled).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// One transaction to refine: its id, merchant description, and Plaid category label.
    struct Item: Sendable {
        let id: UUID
        let description: String
        let rawCategory: String?
    }

    /// Refines vague transactions using the **merchant description** (plus the Plaid category as a hint)
    /// — more accurate than the bare category for buckets like "General Merchandise / Other". Returns
    /// {transactionId: canonical} for the ones it could confidently place.
    static func refine(_ items: [Item], allowed: [String] = CanonicalCategory.all) async -> [UUID: String] {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .available = SystemLanguageModel.default.availability {
            let instructions = """
            You categorize bank transactions into a fixed taxonomy from the merchant/description. Reply \
            with ONLY the single best-matching category name from the allowed list — no punctuation, no \
            explanation.
            """
            var result: [UUID: String] = [:]
            for item in items {
                let session = LanguageModelSession(instructions: instructions)
                let hint = item.rawCategory.map { " (bank category: \($0))" } ?? ""
                let prompt = """
                Allowed categories: \(allowed.joined(separator: ", ")).
                Transaction: "\(item.description)"\(hint).
                Best category:
                """
                guard let response = try? await session.respond(to: prompt) else { continue }
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = allowed.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                    result[item.id] = match
                }
            }
            return result
        }
        #endif
        return [:]
    }

    /// Classifies each raw label into one canonical category. Skips anything the model can't confidently
    /// place in the allowed set. Returns {raw: canonical}.
    static func suggest(for rawLabels: [String], allowed: [String] = CanonicalCategory.all) async -> [String: String] {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .available = SystemLanguageModel.default.availability {
            let instructions = """
            You classify bank-transaction category labels into a fixed taxonomy. Reply with ONLY the \
            single best-matching category name from the allowed list — no punctuation, no explanation.
            """
            var result: [String: String] = [:]
            for raw in rawLabels {
                let session = LanguageModelSession(instructions: instructions)
                let prompt = """
                Allowed categories: \(allowed.joined(separator: ", ")).
                Label: "\(raw)".
                Best category:
                """
                guard let response = try? await session.respond(to: prompt) else { continue }
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if let match = allowed.first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) {
                    result[raw] = match
                }
            }
            return result
        }
        #endif
        return [:]
    }
}
