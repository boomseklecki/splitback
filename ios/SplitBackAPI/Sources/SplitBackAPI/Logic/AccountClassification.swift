import Foundation

/// How an account is summarized in its detail header. Derived from the Plaid subtype string stored in
/// `Account.type` — the backend exposes no explicit asset/liability flag, so we classify by subtype
/// and default anything unrecognized to a transactional cash-flow account.
enum AccountKind {
    /// Transactional deposit accounts (checking, savings, money market, cash management).
    case cashFlow
    /// Credit cards and loans — balance is money owed.
    case liability
    /// Investment / retirement / locked savings vehicles with few or no transactions.
    case holdings

    /// Plaid subtypes (lowercased) treated as liabilities. Includes the top-level `credit`/`loan`
    /// fallbacks for accounts that report no subtype.
    private static let liabilitySubtypes: Set<String> = [
        "credit card", "credit", "loan",
        "auto", "business", "commercial", "construction", "consumer",
        "home equity", "line of credit", "mortgage", "overdraft", "student",
    ]
    /// Plaid subtypes (lowercased) treated as holdings.
    private static let holdingsSubtypes: Set<String> = [
        "investment", "brokerage", "cd",
        "hsa", "ira", "roth", "roth ira", "sep ira", "simple ira",
        "401k", "401a", "403b", "457b", "529", "roth 401k",
        "mutual fund", "stock plan", "pension", "retirement", "keogh",
        "thrift savings plan", "tfsa", "rrsp", "rrif", "lira", "resp", "trust",
    ]

    static func classify(_ type: String?) -> AccountKind {
        let key = (type ?? "").lowercased()
        if liabilitySubtypes.contains(key) { return .liability }
        if holdingsSubtypes.contains(key) { return .holdings }
        return .cashFlow
    }
}
