import SwiftUI

/// A circular avatar that loads a remote image when available and otherwise shows the person's
/// initials on a neutral background.
struct AvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 36

    var body: some View {
        SwiftUI.Group {
            if let url, let resolved = URL(string: url) {
                AsyncImage(url: resolved) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        placeholder
                    } else {
                        ProgressView()
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        Circle()
            .fill(.quaternary)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
            )
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
