import SwiftUI

/// A circular avatar that loads a remote image when available and otherwise shows the person's
/// initials on a neutral background.
struct AvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 36
    /// When there's no remote image, show this SF Symbol instead of initials (e.g. a group-type icon).
    var systemImage: String? = nil
    /// Render a brand/bank logo (fit whole, on a white tile) instead of a photo (fill). Brand logos are
    /// often transparent with dark artwork, so the white tile keeps them visible — including in dark mode.
    var logo: Bool = false

    var body: some View {
        SwiftUI.Group {
            if let url, let resolved = URL(string: url) {
                AsyncImage(url: resolved) { phase in
                    if let image = phase.image {
                        renderImage(image)
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

    @ViewBuilder
    private func renderImage(_ image: Image) -> some View {
        if logo {
            image.resizable().scaledToFit()
                .padding(size * 0.14)
                .frame(width: size, height: size)
                .background(Color.white)  // so dark, transparent logos stay visible in any appearance
        } else {
            image.resizable().scaledToFill()
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(.quaternary)
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.secondary)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
