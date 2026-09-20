import Foundation

/// A failed XRPC call against the PDS.
public enum XRPCError: LocalizedError, Equatable, Sendable {
    /// The PDS answered with a non-2xx status. `error` is its short error
    /// name (`InvalidRequest`, `RecordNotFound`, …) and `message` its
    /// explanation, both when present in the body.
    case server(status: Int, error: String?, message: String?)
    /// The PDS answered 2xx but the body wasn't the JSON we expected.
    case invalidResponse(String)
    /// The session's PDS URL can't be turned into a request URL.
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case let .server(status, error, message):
            if let message, !message.isEmpty {
                return message
            }
            switch status {
            case 401:
                return "Your sign-in has expired. Please sign in to Semble again."
            case 403:
                return "Your account isn't allowed to do that."
            case 404:
                return "Your data server couldn't find what the app asked for."
            case 429:
                return "Your data server asked us to slow down. Try again in a moment."
            case 500 ..< 600:
                return "Your data server is having problems right now. Try again in a moment."
            default:
                if let error, !error.isEmpty {
                    return "Your data server refused the request (\(error))."
                }
                return "Your data server refused the request (HTTP \(status))."
            }
        case .invalidResponse:
            return "Your data server sent a reply the app couldn't understand."
        case .invalidURL:
            return "The address of your data server isn't valid. Try signing in again."
        }
    }

    public var failureReason: String? {
        switch self {
        case let .server(status, error, _):
            return "HTTP \(status)" + (error.map { " (\($0))" } ?? "")
        case let .invalidResponse(detail), let .invalidURL(detail):
            return detail
        }
    }
}
