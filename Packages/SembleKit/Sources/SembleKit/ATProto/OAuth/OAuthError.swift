import Foundation

/// Everything that can go wrong between "sign in" and holding a `Session`.
/// The UI shows `localizedDescription` verbatim, so every case reads as a
/// sentence a person can act on.
public enum OAuthError: LocalizedError, Equatable, Sendable {
    /// A `.well-known` document couldn't be fetched or understood.
    case discoveryFailed(URL)
    /// The metadata document's `issuer` didn't match where we fetched it from,
    /// or the callback's `iss` didn't match the server we started with.
    case issuerMismatch(expected: String, actual: String)
    /// Metadata was fetched but is missing something we need.
    case invalidMetadata(String)
    /// The authorization server answered a PAR, token or refresh request with
    /// an OAuth error (other than the ones with a case of their own).
    case authorizationServerRejected(error: String, description: String?)
    /// The user (or the server) declined the authorization in the browser.
    case authorizationDenied(error: String, description: String?)
    /// The callback's `state` isn't the one we sent.
    case stateMismatch
    /// The callback is missing `code`, `state` or `iss`.
    case invalidCallback(String)
    /// The token response is not a DPoP-bound token.
    case unsupportedTokenType(String)
    /// The token was minted for a different account than the one we resolved.
    case subjectMismatch(expected: String, actual: String)
    /// The refresh token has been revoked or has expired; the user needs to
    /// sign in again.
    case sessionExpired
    /// A response was 2xx but not the JSON we expected.
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .discoveryFailed(url):
            return "Couldn't find the sign-in settings for \(url.hostDescription)."
        case .issuerMismatch:
            return "The sign-in server didn't identify itself correctly, so the sign-in was cancelled for safety."
        case let .invalidMetadata(detail):
            return "The sign-in server's settings are incomplete (\(detail))."
        case let .authorizationServerRejected(error, description):
            if let description, !description.isEmpty {
                return description
            }
            return "The sign-in server refused the request (\(error))."
        case let .authorizationDenied(error, description):
            if error == "access_denied" {
                return "Sign-in was cancelled."
            }
            if let description, !description.isEmpty {
                return description
            }
            return "Sign-in didn't complete (\(error))."
        case .stateMismatch:
            return "This sign-in response doesn't belong to the sign-in you started. Please try again."
        case let .invalidCallback(detail):
            return "The sign-in response was incomplete (\(detail)). Please try again."
        case let .unsupportedTokenType(type):
            return "The sign-in server issued a \(type) token, which this app can't use."
        case .subjectMismatch:
            return "You signed in as a different account than the one you entered. Please try again."
        case .sessionExpired:
            return "Your sign-in has expired. Please sign in to Semble again."
        case let .malformedResponse(detail):
            return "The sign-in server sent a reply the app couldn't understand (\(detail))."
        }
    }
}

extension URL {
    /// The host, for messages ("bsky.social"), falling back to the whole URL.
    var hostDescription: String {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.host ?? absoluteString
    }
}
