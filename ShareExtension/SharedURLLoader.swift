import Foundation
import UniformTypeIdentifiers

/// Pulls a web URL out of what the host app handed the share extension.
///
/// Safari and most apps attach a `public.url`; a few share the link as plain
/// text (or only in `attributedContentText`), so those are scanned with a
/// data detector as a fallback. Only http(s) URLs count.
enum SharedURLLoader {
    /// Returns the first shareable web URL found in `context`, or `nil`.
    static func loadURL(from context: NSExtensionContext?) async -> URL? {
        guard let items = context?.inputItems as? [NSExtensionItem] else { return nil }
        let providers = items.flatMap { $0.attachments ?? [] }

        // 1. A real URL attachment.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadItem(from: provider, typeIdentifier: UTType.url.identifier).flatMap(makeURL(from:)),
               isWebURL(url) {
                return url
            }
        }

        // 2. Plain text containing a URL.
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadItem(from: provider, typeIdentifier: UTType.plainText.identifier).flatMap(makeText(from:)),
               let url = firstWebURL(in: text) {
                return url
            }
        }

        // 3. The item's own text, which some apps use instead of an attachment.
        for item in items {
            if let text = item.attributedContentText?.string, let url = firstWebURL(in: text) {
                return url
            }
        }

        return nil
    }

    // MARK: Helpers

    /// Wraps the completion-handler API so failures simply yield `nil`.
    private static func loadItem(from provider: NSItemProvider, typeIdentifier: String) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }

    /// `loadItem` for `public.url` may hand back a URL, its data, or a string.
    private static func makeURL(from item: NSSecureCoding) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url
        }
        if let string = item as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func makeText(from item: NSSecureCoding) -> String? {
        if let string = item as? String {
            return string
        }
        if let attributed = item as? NSAttributedString {
            return attributed.string
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    /// The first http(s) link a data detector finds in `text`.
    static func firstWebURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, isWebURL(url) {
                return url
            }
        }
        return nil
    }
}
