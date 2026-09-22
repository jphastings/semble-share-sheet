import Foundation

/// Whether a failed write is worth giving up on, or should be tried again
/// later. The one place that decision is made, so `SaveQueue` (retrying a
/// queued save) and `ShareSheetModel` (loading collections) agree on it.
///
/// Permanent: the PDS rejected the request itself (a 4xx other than 401,
/// which means the session — not the request — is the problem) or
/// `SembleLibrary` rejected it before writing anything (an unsupported URL,
/// too-long note). Everything else — connectivity failures, a 401 (the
/// access token needs refreshing, which may itself succeed once the network
/// is back), 429, a 5xx, or a session found to be dead
/// (`OAuthError.sessionExpired`) — is transient: retrying later, once the
/// device is online or the user has signed in again, has a real chance of
/// working.
func isPermanentFailure(_ error: Error) -> Bool {
    if error is SembleLibraryError {
        return true
    }
    if let xrpcError = error as? XRPCError, case let .server(status, _, _) = xrpcError {
        return (400 ..< 500).contains(status) && status != 401 && status != 429
    }
    return false
}
