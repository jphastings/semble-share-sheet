import Foundation

/// Where an account lives: its permanent identifier, its current handle and
/// the PDS that hosts its repository.
public struct ResolvedIdentity: Equatable, Sendable {
    public let did: String
    /// The handle from the DID document, if it declares one.
    public let handle: String?
    /// The user's personal data server, e.g. `https://bsky.social`.
    public let pdsURL: URL

    public init(did: String, handle: String?, pdsURL: URL) {
        self.did = did
        self.handle = handle
        self.pdsURL = pdsURL
    }
}

public enum IdentityError: LocalizedError, Equatable, Sendable {
    case emptyAccount
    case invalidHandle(String)
    case handleNotFound(String)
    case unsupportedDID(String)
    case didDocumentUnavailable(String)
    case invalidDIDDocument(String, reason: String)
    case noPDS(String)
    /// The handle resolved to a DID, but that DID's document doesn't claim
    /// the handle back. Either the handle was just moved or someone is trying
    /// to pass off another account as theirs; refuse both.
    case handleMismatch(handle: String, did: String)

    public var errorDescription: String? {
        switch self {
        case .emptyAccount:
            return "Enter your handle (like alice.bsky.social) to sign in."
        case let .invalidHandle(handle):
            return "“\(handle)” doesn't look like a handle. Handles look like alice.bsky.social."
        case let .handleNotFound(handle):
            return "Couldn't find an account for \(handle). Check the spelling and try again."
        case let .unsupportedDID(did):
            return "\(did) isn't a kind of account this app can sign in to."
        case let .didDocumentUnavailable(did):
            return "Couldn't look up the account \(did). Check your connection and try again."
        case let .invalidDIDDocument(did, reason):
            return "The account record for \(did) is incomplete (\(reason))."
        case let .noPDS(did):
            return "The account \(did) doesn't say where its data is stored, so it can't be used."
        case let .handleMismatch(handle, did):
            return "\(handle) points at \(did), but that account doesn't point back at \(handle). Try again in a moment; if this keeps happening the handle may have moved."
        }
    }
}

/// Turns what the user typed into a DID, handle and PDS URL.
///
/// Handles are resolved through Bluesky's public AppView (which does both
/// the DNS TXT and the HTTPS well-known lookup for us; iOS has no convenient
/// DNS TXT API) with the HTTPS well-known method as a direct fallback. DID
/// documents come from `plc.directory` or the `did:web` host. The identity
/// is only accepted when the DID document points back at the handle, so a
/// handle can't be spoofed by whoever answers the first lookup.
public struct IdentityResolver: Sendable {
    private let http: HTTPClient

    /// Bluesky's public, unauthenticated AppView.
    static let resolveHandleURL = URL(string: "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle")!
    static let plcDirectory = URL(string: "https://plc.directory")!

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Accepts a handle ("alice.bsky.social", "@alice.bsky.social") or a DID
    /// ("did:plc:…", "did:web:…"). Surrounding whitespace is ignored.
    public func resolve(_ account: String) async throws -> ResolvedIdentity {
        let account = IdentityResolver.normalize(account)
        guard !account.isEmpty else {
            throw IdentityError.emptyAccount
        }

        let did: String
        let typedHandle: String?
        if account.hasPrefix("did:") {
            did = account
            typedHandle = nil
        } else {
            guard IdentityResolver.looksLikeHandle(account) else {
                throw IdentityError.invalidHandle(account)
            }
            did = try await resolveHandle(account)
            typedHandle = account
        }

        let document = try await didDocument(for: did)
        guard document.id == did else {
            throw IdentityError.invalidDIDDocument(did, reason: "it describes \(document.id)")
        }

        let handles = document.alsoKnownAs
            .filter { $0.hasPrefix("at://") }
            .map { String($0.dropFirst("at://".count)) }

        if let typedHandle {
            guard handles.contains(where: { $0.lowercased() == typedHandle }) else {
                throw IdentityError.handleMismatch(handle: typedHandle, did: did)
            }
        }

        guard let pds = document.service.first(where: {
            $0.id.hasSuffix("#atproto_pds") && $0.type == "AtprotoPersonalDataServer"
        }), let endpoint = pds.serviceEndpoint, let pdsURL = URL(string: endpoint) else {
            throw IdentityError.noPDS(did)
        }

        return ResolvedIdentity(did: did, handle: handles.first, pdsURL: pdsURL)
    }

    /// Trims whitespace, drops a leading `@`, and lower-cases handles
    /// (handles are case-insensitive; DIDs are left alone).
    static func normalize(_ account: String) -> String {
        var trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@") {
            trimmed.removeFirst()
        }
        return trimmed.hasPrefix("did:") ? trimmed : trimmed.lowercased()
    }

    /// A handle is a hostname: at least one dot, no slashes or spaces.
    static func looksLikeHandle(_ handle: String) -> Bool {
        guard handle.contains("."), !handle.hasPrefix("."), !handle.hasSuffix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return handle.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Handle → DID

    private func resolveHandle(_ handle: String) async throws -> String {
        if let did = await resolveHandleViaAppView(handle) {
            return did
        }
        if let did = await resolveHandleViaWellKnown(handle) {
            return did
        }
        throw IdentityError.handleNotFound(handle)
    }

    private func resolveHandleViaAppView(_ handle: String) async -> String? {
        guard var components = URLComponents(url: IdentityResolver.resolveHandleURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "handle", value: handle)]
        guard let url = components.url else { return nil }

        guard let response = try? await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"])),
              response.isSuccess,
              let body = try? response.decode(ResolveHandleResponse.self),
              body.did.hasPrefix("did:")
        else {
            return nil
        }
        return body.did
    }

    private func resolveHandleViaWellKnown(_ handle: String) async -> String? {
        guard let url = URL(string: "https://\(handle)/.well-known/atproto-did") else { return nil }
        guard let response = try? await http.send(HTTPRequest(url: url)), response.isSuccess else {
            return nil
        }
        // The body is the DID as plain text, possibly with a trailing newline.
        let did = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard did.hasPrefix("did:"), !did.contains("\n") else { return nil }
        return did
    }

    // MARK: - DID → document

    private func didDocument(for did: String) async throws -> DIDDocument {
        let url = try IdentityResolver.documentURL(for: did)
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"]))
        } catch {
            throw IdentityError.didDocumentUnavailable(did)
        }
        guard response.isSuccess else {
            throw IdentityError.didDocumentUnavailable(did)
        }
        do {
            return try response.decode(DIDDocument.self)
        } catch {
            throw IdentityError.invalidDIDDocument(did, reason: "not a DID document")
        }
    }

    /// `did:plc:…` documents live in the PLC directory. `did:web:host` ones
    /// live at `https://host/.well-known/did.json` (extra colon-separated
    /// segments become path segments, per the did:web spec; ATProto only
    /// allows the bare-host form but the general case costs nothing).
    static func documentURL(for did: String) throws -> URL {
        if did.hasPrefix("did:plc:") {
            guard did.count > "did:plc:".count, let url = URL(string: "\(plcDirectory.absoluteString)/\(did)") else {
                throw IdentityError.unsupportedDID(did)
            }
            return url
        }
        if did.hasPrefix("did:web:") {
            let identifier = did.dropFirst("did:web:".count)
            let segments = identifier.split(separator: ":").map { String($0).removingPercentEncoding ?? String($0) }
            guard let host = segments.first, !host.isEmpty, !host.contains("/") else {
                throw IdentityError.unsupportedDID(did)
            }
            let path = segments.dropFirst().isEmpty
                ? "/.well-known/did.json"
                : "/" + segments.dropFirst().joined(separator: "/") + "/did.json"
            guard let url = URL(string: "https://\(host)\(path)") else {
                throw IdentityError.unsupportedDID(did)
            }
            return url
        }
        throw IdentityError.unsupportedDID(did)
    }
}

// MARK: - Wire types

struct ResolveHandleResponse: Decodable {
    let did: String
}

/// The parts of a DID document ATProto cares about. Decoding is lenient
/// about everything else: real documents carry verification methods and
/// services we don't understand, and `serviceEndpoint` is allowed to be an
/// object for other DID methods.
struct DIDDocument: Decodable, Equatable {
    let id: String
    let alsoKnownAs: [String]
    let service: [Service]

    struct Service: Decodable, Equatable {
        let id: String
        let type: String
        let serviceEndpoint: String?

        enum CodingKeys: String, CodingKey {
            case id, type, serviceEndpoint
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            type = (try? container.decode(String.self, forKey: .type)) ?? ""
            serviceEndpoint = try? container.decode(String.self, forKey: .serviceEndpoint)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, alsoKnownAs, service
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        alsoKnownAs = try container.decodeIfPresent([String].self, forKey: .alsoKnownAs) ?? []
        service = try container.decodeIfPresent([Service].self, forKey: .service) ?? []
    }
}
