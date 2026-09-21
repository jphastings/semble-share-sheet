import AuthenticationServices
import Foundation
import OAuthenticator
import Observation
import SembleKit
import SwiftUI

/// Owns the signed-in `Session` for the app: loads it from the shared
/// Keychain, runs the OAuth sign-in through the system browser, and clears
/// it on log out.
@MainActor
@Observable
final class AccountModel {
    /// The current session, or `nil` when signed out.
    private(set) var session: Session?
    /// True from tapping "Log in" until the browser flow finishes or fails.
    private(set) var isSigningIn = false
    /// A user-presentable message from the last failed sign-in.
    private(set) var error: String?

    private let sessionStore: any SessionStore
    private let oauth: OAuthClient

    init(
        sessionStore: any SessionStore = AppEnvironment.sessionStore,
        oauth: OAuthClient = AppEnvironment.oauthClient
    ) {
        self.sessionStore = sessionStore
        self.oauth = oauth
        self.session = (try? sessionStore.load()) ?? nil
    }

    /// Runs the full ATProto OAuth flow for `account` (a handle or DID) using
    /// the SwiftUI `webAuthenticationSession` from the calling view. A
    /// cancelled browser sheet is not treated as an error.
    func signIn(account: String, using browser: WebAuthenticationSession) async {
        let account = Self.normalize(account)
        guard !account.isEmpty, !isSigningIn else { return }

        isSigningIn = true
        error = nil
        defer { isSigningIn = false }

        do {
            // OAuthenticator drives the browser through SwiftUI's session; the
            // ephemeral mode keeps the PDS login out of Safari's cookie jar.
            let openBrowser = browser.userAuthenticator(preferredBrowserSession: .ephemeral)
            let session = try await oauth.signIn(account: account, openBrowser: openBrowser)
            try sessionStore.save(session)
            self.session = session
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // The user closed the browser sheet; nothing to report.
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Forgets the session locally. Tokens are not revoked server-side.
    func signOut() {
        try? sessionStore.clear()
        session = nil
        error = nil
    }

    /// Trims whitespace and a leading "@", which people naturally type.
    private static func normalize(_ account: String) -> String {
        var trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") {
            trimmed.removeFirst()
        }
        return trimmed
    }
}
