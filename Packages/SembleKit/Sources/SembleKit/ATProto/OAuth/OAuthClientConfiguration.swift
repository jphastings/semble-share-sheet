import Foundation

/// How this app identifies itself to authorization servers.
///
/// ATProto has no client registration step: the `client_id` *is* a URL to a
/// public JSON document describing the client (its redirect URIs, scopes,
/// that it is a public native app using DPoP). Servers fetch it on demand.
public struct OAuthClientConfiguration: Equatable, Sendable {
    /// URL of the client metadata document, e.g.
    /// `https://semble-share.byjp.me/oauth-client-metadata.json`.
    public var clientID: URL
    /// Where the browser sends the user back to, e.g.
    /// `me.byjp.semble-share:/oauth/callback`. Must be listed in the metadata
    /// document.
    public var redirectURI: URL
    /// Space-separated OAuth scopes. Must include `atproto`.
    public var scope: String

    public init(clientID: URL, redirectURI: URL, scope: String) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scope = scope
    }

    /// The `client_id` as sent on the wire.
    var clientIDString: String { clientID.absoluteString }
}
