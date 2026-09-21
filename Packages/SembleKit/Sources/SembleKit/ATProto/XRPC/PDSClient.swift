import Foundation
import OAuthenticator

/// Authenticated XRPC calls against the session's own PDS.
///
/// Requests go through an OAuthenticator `Authenticator` in manual-only
/// mode, which adds the `DPoP` proof and `Authorization` header, retries
/// once when the PDS asks for a fresh nonce, and refreshes an expired access
/// token before retrying. A refreshed session is written back to the
/// `SessionStore` so the app and the extension stay in step. The client
/// never opens a browser: when the refresh token itself is dead the call
/// fails with `OAuthError.sessionExpired`, the stored session is cleared,
/// and the user has to sign in again through the app.
public actor PDSClient {
    private let vault: SessionVault
    private let authenticator: Authenticator

    public init(
        session: Session,
        sessionStore: SessionStore,
        configuration: OAuthClientConfiguration,
        http: HTTPClient = URLSessionHTTPClient()
    ) {
        let vault = SessionVault(session: session, store: sessionStore)
        self.vault = vault

        let expectedDID = session.did
        let tokenHandling = Bluesky.tokenHandling(
            account: nil,
            server: session.authorizationServer,
            jwtGenerator: DPoPProofs.generator(for: session.dpopKey),
            validator: { response, _ in response.sub == expectedDID }
        )
        // OAuthenticator clears its storage whenever a refresh fails, even on
        // a dropped connection. That would log the user out for being
        // offline, so the clear is a no-op here and `perform` clears the
        // store only when the server says the refresh token is dead.
        let storage = LoginStorage(
            retrieveLogin: { vault.current.login },
            storeLogin: { login in try vault.update(login: login) },
            clearLogin: {}
        )
        self.authenticator = Authenticator(
            config: Authenticator.Configuration(
                appCredentials: configuration.appCredentials,
                loginStorage: storage,
                tokenHandling: tokenHandling,
                mode: .manualOnly,
                userAuthenticator: { url, scheme in try Authenticator.failingUserAuthenticator(url, scheme) }
            ),
            urlLoader: http.urlResponseProvider
        )
    }

    /// The account whose repository this client writes to.
    public var did: String { vault.current.did }

    /// The session as it currently stands (tokens may have been refreshed
    /// since the client was created).
    public var currentSession: Session { vault.current }

    // MARK: - Records

    /// `com.atproto.repo.createRecord`. The PDS assigns the record key.
    public func createRecord<R: Encodable>(collection: String, record: R) async throws -> StrongRef {
        let input = CreateRecordInput(repo: did, collection: collection, record: record)
        let response = try await post("com.atproto.repo.createRecord", body: input)
        return try decode(StrongRef.self, from: response)
    }

    /// `com.atproto.repo.listRecords`, newest first.
    public func listRecords<R: Decodable>(collection: String, limit: Int = 100, cursor: String? = nil) async throws -> RecordPage<R> {
        var query = [
            ("repo", did),
            ("collection", collection),
            ("limit", String(limit)),
        ]
        if let cursor, !cursor.isEmpty {
            query.append(("cursor", cursor))
        }
        let response = try await get("com.atproto.repo.listRecords", query: query)
        return try decode(RecordPage<R>.self, from: response)
    }

    /// `com.atproto.repo.getRecord`.
    public func getRecord<R: Decodable>(collection: String, rkey: String) async throws -> RecordEnvelope<R> {
        let response = try await get("com.atproto.repo.getRecord", query: [
            ("repo", did),
            ("collection", collection),
            ("rkey", rkey),
        ])
        return try decode(RecordEnvelope<R>.self, from: response)
    }

    /// `com.atproto.repo.deleteRecord`. Deleting a record that doesn't exist
    /// is not an error, as on the PDS.
    public func deleteRecord(collection: String, rkey: String) async throws {
        let input = DeleteRecordInput(repo: did, collection: collection, rkey: rkey)
        _ = try await post("com.atproto.repo.deleteRecord", body: input)
    }

    // MARK: - Transport

    private func get(_ nsid: String, query: [(String, String)]) async throws -> HTTPResponse {
        var request = URLRequest(url: try xrpcURL(nsid, query: query))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func post<Body: Encodable>(_ nsid: String, body: Body) async throws -> HTTPResponse {
        var request = URLRequest(url: try xrpcURL(nsid, query: []))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No date strategy on purpose: record types format their own dates
        // as ATProto wants them (RFC 3339 with fractional seconds and `Z`).
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    /// Sends `request` through the authenticator and turns a non-2xx answer
    /// into an `XRPCError`, or a dead session into `OAuthError.sessionExpired`.
    private func perform(_ request: URLRequest) async throws -> HTTPResponse {
        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await authenticator.response(for: request)
        } catch let error as AuthenticatorError {
            if case .invalidGrant = error {
                // The authorization server has rejected the refresh token
                // outright; nothing short of signing in again will help.
                try? vault.clear()
            }
            throw OAuthError.fromAuthenticator(error)
        }
        guard let http = urlResponse as? HTTPURLResponse else {
            throw XRPCError.invalidResponse("Not an HTTP response")
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        let response = HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        guard response.isSuccess else {
            let body = try? response.decode(XRPCErrorBody.self)
            throw XRPCError.server(status: response.statusCode, error: body?.error, message: body?.message)
        }
        return response
    }

    private func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T {
        do {
            return try response.decode(T.self)
        } catch {
            throw XRPCError.invalidResponse("\(T.self): \(error)")
        }
    }

    /// `<pdsURL>/xrpc/<nsid>?<query>`.
    private func xrpcURL(_ nsid: String, query: [(String, String)]) throws -> URL {
        let pdsURL = vault.current.pdsURL
        guard var components = URLComponents(url: pdsURL, resolvingAgainstBaseURL: false) else {
            throw XRPCError.invalidURL(pdsURL.absoluteString)
        }
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path + "/xrpc/" + nsid
        components.fragment = nil
        if query.isEmpty {
            components.percentEncodedQuery = nil
        } else {
            components.percentEncodedQuery = query
                .map { "\($0.0.formURLEncodedComponent)=\($0.1.formURLEncodedComponent)" }
                .joined(separator: "&")
        }
        guard let url = components.url else {
            throw XRPCError.invalidURL(pdsURL.absoluteString)
        }
        return url
    }
}

/// The live `Session` shared between the actor and OAuthenticator's storage
/// callbacks. Token refreshes land here first and are then persisted.
final class SessionVault: @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session
    private let store: SessionStore

    init(session: Session, store: SessionStore) {
        self.session = session
        self.store = store
    }

    var current: Session {
        lock.withLock { session }
    }

    /// Records rotated tokens and persists the whole session.
    func update(login: Login) throws {
        var updated = lock.withLock { session }
        updated.login = login
        // Keep the in-memory copy even if persisting fails: the old refresh
        // token is already spent, so this process must carry on with the new one.
        lock.withLock { session = updated }
        try store.save(updated)
    }

    func clear() throws {
        try store.clear()
    }
}

// MARK: - Wire types

struct CreateRecordInput<Record: Encodable>: Encodable {
    let repo: String
    let collection: String
    let record: Record
}

struct DeleteRecordInput: Encodable {
    let repo: String
    let collection: String
    let rkey: String
}

/// The body of an XRPC error: `{"error": "Name", "message": "Explanation"}`.
struct XRPCErrorBody: Decodable {
    let error: String?
    let message: String?
}
