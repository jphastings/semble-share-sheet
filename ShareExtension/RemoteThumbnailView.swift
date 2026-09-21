import ImageIO
import SwiftUI

/// Loads a small thumbnail from an already-https `URL` without ever holding a
/// full decoded image in memory: the extension has a tight budget, and the
/// URL names an arbitrary page's own og:image. Bounded on every axis — a
/// short timeout, a byte cap enforced while streaming, and a thumbnail decode
/// that never touches the full-size image — and fails closed to the same
/// placeholder colour the card shows before any preview has loaded.
struct RemoteThumbnailView: View {
    let url: URL
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: Image?

    var body: some View {
        ZStack {
            Color.sembleStone200
            image?
                .resizable()
                .scaledToFill()
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            image = await Self.loadThumbnail(from: url, maxPixelSize: Int((side * displayScale).rounded(.up)))
        }
    }

    /// Well above any og:image worth showing at 45pt; anything bigger aborts
    /// mid-stream rather than being decoded.
    private static let byteCap = 5 * 1024 * 1024

    private static func loadThumbnail(from url: URL, maxPixelSize: Int) async -> Image? {
        guard url.scheme == "https" else { return nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            if response.expectedContentLength > Int64(byteCap) {
                return nil
            }

            // ponytail: byte-at-a-time because AsyncBytes offers nothing
            // coarser; fine for a thumbnail, but chunk it if a big image ever
            // makes the card visibly slow to fill.
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > byteCap { return nil }
            }

            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            // `.resizable()` below rescales to `side` regardless of the
            // scale declared here, so 1 (pixels as points) is fine.
            return Image(decorative: thumbnail, scale: 1)
        } catch {
            return nil
        }
    }
}
