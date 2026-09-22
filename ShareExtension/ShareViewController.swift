import SembleKit
import SwiftUI
import UIKit

/// The share extension's principal class (see `NSExtensionPrincipalClass` in
/// `project.yml`). It is a thin UIKit shell: it works out what was shared,
/// loads the session from the shared Keychain, builds the `ShareSheetModel`
/// and hosts the SwiftUI sheet. All decisions live in the model.
final class ShareViewController: UIViewController {
    /// How long a PDS request may go without hearing back before it fails,
    /// so a save on a useless connection lands in the queue promptly. It's
    /// an idle timeout, so a slow but working transfer isn't cut off.
    // ponytail: per request, not a cap on the whole save (refresh + card +
    // note + links can each take up to 10 s); add an overall deadline if
    // that shows up in practice.
    private static let requestTimeout: TimeInterval = 10

    private var model: ShareSheetModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        // Finding the URL is asynchronous (the host app streams it to us), but
        // it is fast; the sheet appears as soon as it's known.
        Task { [weak self] in
            guard let self else { return }
            let url = await SharedURLLoader.loadURL(from: self.extensionContext)
            self.showSheet(for: url)
        }
    }

    // MARK: Building the sheet

    private func showSheet(for url: URL?) {
        let session = (try? AppEnvironment.sessionStore.load()) ?? nil
        let library: (any Library)? = session.map { AppEnvironment.makeLibrary(session: $0, requestTimeout: Self.requestTimeout) }
        let metadataClient = URLMetadataClient()

        // Don't block the sheet on this: whatever's already queued from a
        // previous offline attempt gets a chance to go out now, but the
        // sheet the user is looking at is for a new save.
        if let session, let library {
            Task.detached(priority: .utility) {
                await AppEnvironment.saveQueue.drain(for: session.did, using: library)
            }
        }

        let model = ShareSheetModel(
            library: library,
            metadata: { url in try await metadataClient.preview(for: url) },
            url: url,
            did: session?.did,
            queue: AppEnvironment.saveQueue,
            collectionsCache: AppEnvironment.collectionsCache
        )
        self.model = model

        let sheet = ShareSheetView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onComplete: { [weak self] in self?.complete() }
        )
        let host = UIHostingController(rootView: sheet)
        host.view.backgroundColor = UIColor.systemBackground

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    // MARK: Finishing

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func cancel() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        extensionContext?.cancelRequest(withError: error)
    }
}
