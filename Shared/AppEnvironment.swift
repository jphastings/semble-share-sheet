import Foundation
import SembleKit

/// The handful of constants and factories both the app and the share
/// extension need. Everything here is deliberately static and obvious: the
/// identifiers are mirrored in `project.yml`, the CI config and the hosted
/// OAuth client metadata, so change them there too.
enum AppEnvironment {
    // MARK: Identifiers

    /// Shared container for anything both targets need on disk.
    static let appGroup = "group.me.byjp.SembleShare"

    /// Keychain service name under which the `Session` is stored.
    static let keychainService = "me.byjp.SembleShare.session"

    /// The keychain access group *without* its team prefix; see `keychainAccessGroup`.
    private static let keychainAccessGroupSuffix = "me.byjp.SembleShare"

    // MARK: OAuth

    /// The hosted client metadata document doubles as the ATProto `client_id`.
    static let oauthClientID = URL(string: "https://semble-share.byjp.me/oauth-client-metadata.json")!

    /// Custom-scheme redirect registered in the app's `CFBundleURLTypes`.
    static let oauthRedirectURI = URL(string: "me.byjp.semble-share:/oauth/callback")!

    /// The scheme part of `oauthRedirectURI`, as `ASWebAuthenticationSession` wants it.
    static let oauthCallbackScheme = "me.byjp.semble-share"

    /// `atproto` plus Semble's permission set, which unlocks the `network.cosmik.*` collections.
    static let oauthScope = "atproto include:network.cosmik.authFull"

    /// Where "Open Semble" goes.
    static let sembleWebsiteURL = SembleConfiguration.production.websiteURL

    // MARK: Keychain access group

    /// The shared keychain access group, e.g. `ABCDE12345.me.byjp.SembleShare`.
    ///
    /// The app and the extension must read and write the *same* keychain item,
    /// so the item has to live in the access group both entitlements list.
    /// That group is prefixed with the team identifier, which the build knows
    /// (`$(AppIdentifierPrefix)`) but code cannot easily discover at runtime, so
    /// both Info.plists carry an `AppIdentifierPrefix` key that Xcode expands
    /// at build time and we read it back here.
    ///
    /// On an unsigned build (simulator with `CODE_SIGNING_ALLOWED=NO`, or no
    /// team configured) the prefix expands to an empty string. In that case we
    /// return `nil` so the keychain falls back to the process's default group
    /// and local development still works; the app and extension then simply
    /// don't share a session on that build.
    static var keychainAccessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String else {
            return nil
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unexpanded "$(AppIdentifierPrefix)" means the build setting was missing.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed + keychainAccessGroupSuffix
    }

    // MARK: Factories

    /// The one session store both targets use.
    static let sessionStore: KeychainSessionStore = KeychainSessionStore(
        service: keychainService,
        accessGroup: keychainAccessGroup
    )

    static let oauthConfiguration = OAuthClientConfiguration(
        clientID: oauthClientID,
        redirectURI: oauthRedirectURI,
        scope: oauthScope
    )

    static let oauthClient = OAuthClient(configuration: oauthConfiguration)

    /// An authenticated client for the signed-in user's own PDS. Token refreshes
    /// are written back to `sessionStore` transparently.
    static func makePDSClient(session: Session) -> PDSClient {
        PDSClient(session: session, sessionStore: sessionStore, oauth: oauthClient)
    }

    /// The Semble "library" (collections + save) for the signed-in user.
    static func makeLibrary(session: Session) -> SembleLibrary {
        SembleLibrary(pds: makePDSClient(session: session))
    }
}
