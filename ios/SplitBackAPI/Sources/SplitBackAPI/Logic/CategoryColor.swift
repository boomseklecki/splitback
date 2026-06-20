import SwiftUI

/// A stable color for a category, for the spending donut and budget bars. Canonical categories get a
/// fixed hue; anything else hashes into the same palette so colors stay consistent across renders.
func categoryColor(_ category: String?) -> Color {
    guard let category, !category.isEmpty else { return .gray }
    if let fixed = palette[category] { return fixed }
    let index = abs(category.hashValue) % wheel.count
    return wheel[index]
}

private let wheel: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint,
    .red, .cyan, .yellow, .brown,
]

private let palette: [String: Color] = [
    "Groceries": .green,
    "Dining": .orange,
    "Transport": .blue,
    "Fuel": .indigo,
    "Utilities": .yellow,
    "Rent": .brown,
    "Mortgage": .brown,
    "Entertainment": .pink,
    "Travel": .teal,
    "Health": .red,
    "Insurance": .gray,
    "Shopping": .purple,
    "Household": .mint,
    "Subscriptions": .cyan,
    "Education": .blue,
    "Gifts": .pink,
    "Personal Care": .purple,
    "Pets": .brown,
    "Fees": .gray,
    "Income": .green,
    "Transfer": .gray,
    "Settle-up": .gray,
    "Other": .secondary,
]
