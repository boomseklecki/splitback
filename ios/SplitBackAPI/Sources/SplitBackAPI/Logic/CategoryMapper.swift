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

    /// Classifies each raw label into one canonical category. Skips anything the model can't confidently
    /// place in the allowed set. Returns {raw: canonical}.
    static func suggest(for rawLabels: [String]) async -> [String: String] {
        #if canImport(FoundationModels)
        if #available(iOS 26, *), case .available = SystemLanguageModel.default.availability {
            let allowed = CanonicalCategory.all
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
