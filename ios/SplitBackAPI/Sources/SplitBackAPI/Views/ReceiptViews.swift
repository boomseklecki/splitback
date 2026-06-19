import SwiftUI
import SwiftData
import UIKit

/// In-memory cache of decoded receipt images, replacing the `URLCache` that `AsyncImage` gave us with
/// the old presigned URLs. Bytes now come from the API (`/receipts/{id}/content`).
@MainActor
final class ReceiptImageStore {
    static let shared = ReceiptImageStore()
    private let cache = NSCache<NSUUID, UIImage>()

    func image(for receiptId: UUID, using repository: ReceiptRepository) async -> UIImage? {
        if let cached = cache.object(forKey: receiptId as NSUUID) { return cached }
        guard let data = try? await repository.imageData(receiptId: receiptId),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: receiptId as NSUUID)
        return image
    }
}

/// A square receipt thumbnail, loaded from the API and cached.
struct ReceiptThumbnail: View {
    let receipt: Receipt

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        SwiftUI.Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if loading {
                ProgressView()
            } else {
                Image(systemName: "doc.text.image").foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .task {
            defer { loading = false }
            image = await ReceiptImageStore.shared.image(for: receipt.id, using: env.receipts(context))
        }
    }
}

/// Full-screen receipt image viewer.
struct ReceiptViewerView: View {
    let receipt: Receipt

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            SwiftUI.Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if loading {
                    ProgressView()
                } else {
                    ContentUnavailableView("Couldn't Load Receipt", systemImage: "doc.text.image")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task {
                defer { loading = false }
                image = await ReceiptImageStore.shared.image(for: receipt.id, using: env.receipts(context))
            }
        }
    }
}
