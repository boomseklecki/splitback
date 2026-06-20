import Foundation

/// SF Symbol for a category: a user-chosen icon from the synced catalog if set, otherwise a
/// keyword match on the name (Splitwise or self-hosted), falling back to a generic tag.
@MainActor
func categorySymbol(_ category: String?) -> String {
    guard let name = category, !name.isEmpty else { return "tag" }
    if let custom = CategoryCatalog.shared.icon(for: name) { return custom }
    let c = name.lowercased()
    let map: [(String, String)] = [
        ("settle", "arrow.left.arrow.right"),
        ("payment", "arrow.left.arrow.right"),
        ("reimburs", "arrow.uturn.backward.circle"),
        ("personal care", "comb"),  // before "car" — "personal care".contains("car")
        ("grocer", "cart.fill"),
        ("dining", "fork.knife"),
        ("restaurant", "fork.knife"),
        ("food", "fork.knife"),
        ("coffee", "cup.and.saucer.fill"),
        ("liquor", "wineglass.fill"),
        ("bar", "wineglass.fill"),
        ("rent", "house.fill"),
        ("mortgage", "house.fill"),
        ("hous", "house.fill"),
        ("furnit", "sofa.fill"),
        ("electric", "bolt.fill"),
        ("util", "bolt.fill"),
        ("water", "drop.fill"),
        ("trash", "trash.fill"),
        ("internet", "wifi"),
        ("tv", "tv"),
        ("phone", "phone.fill"),
        ("fuel", "fuelpump.fill"),
        ("gas", "fuelpump.fill"),
        ("parking", "parkingsign"),
        ("taxi", "car.fill"),
        ("car", "car.fill"),
        ("transport", "bus.fill"),
        ("flight", "airplane"),
        ("travel", "airplane"),
        ("hotel", "bed.double.fill"),
        ("lodging", "bed.double.fill"),
        ("movie", "film.fill"),
        ("entertain", "film.fill"),
        ("game", "gamecontroller.fill"),
        ("music", "music.note"),
        ("cloth", "tshirt.fill"),
        ("shop", "bag.fill"),
        ("medical", "cross.case.fill"),
        ("health", "cross.case.fill"),
        ("pharma", "pills.fill"),
        ("insur", "shield.fill"),
        ("gift", "gift.fill"),
        ("donat", "gift.fill"),
        ("pet", "pawprint.fill"),
        ("educa", "book.fill"),
        ("bill", "doc.text.fill"),
    ]
    for (key, symbol) in map where c.contains(key) {
        return symbol
    }
    return "tag"
}

/// Curated SF Symbols offered when picking a category icon.
let categoryIconChoices: [String] = [
    "tag", "cart.fill", "fork.knife", "cup.and.saucer.fill", "wineglass.fill",
    "house.fill", "sofa.fill", "bolt.fill", "drop.fill", "flame.fill", "trash.fill",
    "wifi", "tv", "phone.fill", "fuelpump.fill", "car.fill", "bus.fill", "tram.fill",
    "bicycle", "airplane", "bed.double.fill", "film.fill", "gamecontroller.fill",
    "music.note", "headphones", "tshirt.fill", "bag.fill", "gift.fill", "cross.case.fill",
    "pills.fill", "heart.fill", "figure.run", "dumbbell.fill", "pawprint.fill",
    "book.fill", "graduationcap.fill", "doc.text.fill", "creditcard.fill", "banknote.fill",
    "dollarsign.circle.fill", "building.columns.fill", "briefcase.fill", "hammer.fill",
    "wrench.and.screwdriver.fill", "scissors", "comb", "sparkles", "leaf.fill",
    "shippingbox.fill", "takeoutbag.and.cup.and.straw.fill", "popcorn.fill",
    "shield.fill", "umbrella.fill", "star.fill", "ticket.fill",
]
