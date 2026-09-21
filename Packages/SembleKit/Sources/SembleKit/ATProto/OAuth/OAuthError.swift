import Foundation
import OAuthenticator

/// What can go wrong signing in or keeping a session alive. The UI shows
/// `localizedDescription` verbatim, so every case reads as a sentence a
/// person can act on.
public enum OAuthError: LocalizedError, Equatable, Sendable {
    /// The PDS's or authorization server's `.well-known` document couldn't be
    /// fetched or understood. The payload names the host.
    case discoveryFailed(String)
    /// The metadata document's `issuer` didn't match where it was fetched from.
    case issuerMismatch
    /// The browser came back with a callback that doesn't belong to the sign-in
    /// we started (wrong `state` or `iss`, or missing `code`).
    case callbackRejected
    /// The token was minted for a different account than the one entered.
    case subjectMismatch
    /// The authorization server refused a request. The payload is its
    /// explanation when it gave one, otherwise its error code.
    case authorizationServerRejected(String)
    /// The refresh token has been revoked or has expired; the user needs to
    /// sign in again.
    case sessionExpired

    public var errorDescription: String? {
        switch self {
        case let .discoveryFailed(host):
            return "Couldn't find the sign-in settings for \(host)."
        case .issuerMismatch:
            return "The sign-in server didn't identify itself correctly, so the sign-in was cancelled for safety."
        case .callbackRejected:
            return "This sign-in response doesn't belong to the sign-in you started. Please try again."
        case .subjectMismatch:
            return "You signed in as a different account than the one you entered. Please try again."
        case let .authorizationServerRejected(reason):
            return "The sign-in server refused the request: \(reason)"
        case .sessionExpired:
            return "Your Semble sign-in has expired. Open the Add to Semble app and log in again."
        }
    }

    /// Translates OAuthenticator's errors into ours. Anything not recognised
    /// (network failures, the user cancelling the browser) is left alone so
    /// callers can inspect it themselves.
    static func fromAuthenticator(_ error: Error) -> Error {
        guard let error = error as? AuthenticatorError else { return error }
        switch error {
        case .tokenInvalid:
            // Our token validator rejected the `sub`; the library reports that
            // as an invalid token.
            return OAuthError.subjectMismatch
        case .stateTokenMismatch, .issuingServerMismatch, .missingAuthorizationCode:
            return OAuthError.callbackRejected
        case let .invalidRequest(code, description), let .unrecognizedError(code, description):
            return OAuthError.authorizationServerRejected(description.isEmpty ? code : description)
        case let .dpopTokenExpected(type):
            return OAuthError.authorizationServerRejected("it issued a \(type) token instead of a DPoP one")
        case .invalidGrant, .manualAuthenticationRequired, .unauthorizedRefreshFailed, .refreshNotPossible, .missingRefreshToken:
            return OAuthError.sessionExpired
        default:
            return error
        }
    }
}
