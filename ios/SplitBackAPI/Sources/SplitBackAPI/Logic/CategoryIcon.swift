import Foundation

/// Best-effort SF Symbol for an expense category (Splitwise or self-hosted names), keyword-matched.
/// Unknown/empty categories fall back to a generic tag.
func categorySymbol(_ category: String?) -> String {
    guard let c = category?.lowercased(), !c.isEmpty else { return "tag" }
    let map: [(String, String)] = [
        ("settle", "arrow.left.arrow.right"),
        ("payment", "arrow.left.arrow.right"),
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
