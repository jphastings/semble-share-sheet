import Foundation

/// Authenticated XRPC calls against the session's own PDS.
///
/// Every request carries `Authorization: DPoP <access token>` and a `DPoP`
/// proof signed by the session's key. The client transparently:
///
/// - retries once with the server's nonce when the PDS answers
///   `use_dpop_nonce` (and remembers nonces it sees for next time);
/// - refreshes the access token when it is about to expire, or when the PDS
///   says it has (`invalid_token` / `ExpiredToken`), persists the rotated
///   session to the store, and retries once.
///
/// Each of those happens at most once per call, so a broken server can't
/// make the client loop.
public actor PDSClient {
    private var session: Session
    private let sessionStore: SessionStore
    private let oauth: OAuthClient
    private let http: HTTPClient
    /// Latest `DPoP-Nonce` per origin. The PDS is one origin; keyed anyway
    /// in case a session's PDS URL ever changes underneath us.
    private var nonces: [String: String] = [:]

    public init(session: Session, sessionStore: SessionStore, oauth: OAuthClient, http: HTTPClient = URLSessionHTTPClient()) {
        self.session = session
        self.sessionStore = sessionStore
        self.oauth = oauth
        self.http = http
    }

    /// The account whose repository this client writes to.
    public var did: String { session.did }

    /// The session as it currently stands (tokens may have been refreshed
    /// since the client was created).
    public var currentSession: Session { session }

    // MARK: - Records

    /// `com.atproto.repo.createRecord`. The PDS assigns the record key.
    public func createRecord<R: Encodable>(collection: String, record: R) async throws -> StrongRef {
        let input = CreateRecordInput(repo: session.did, collection: collection, record: record)
        let response = try await post("com.atproto.repo.createRecord", body: input)
        return try decode(StrongRef.self, from: response)
    }

    /// `com.atproto.repo.listRecords`, newest first.
    public func listRecords<R: Decodable>(collection: String, limit: Int = 100, cursor: String? = nil) async throws -> RecordPage<R> {
        var query = [
            ("repo", session.did),
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
            ("repo", session.did),
            ("collection", collection),
            ("rkey", rkey),
        ])
        return try decode(RecordEnvelope<R>.self, from: response)
    }

    /// `com.atproto.repo.deleteRecord`. Deleting a record that doesn't exist
    /// is not an error, as on the PDS.
    public func deleteRecord(collection: String, rkey: String) async throws {
        let input = DeleteRecordInput(repo: session.did, collection: collection, rkey: rkey)
        _ = try await post("com.atproto.repo.deleteRecord", body: input)
    }

    // MARK: - Transport

    private func get(_ nsid: String, query: [(String, String)]) async throws -> HTTPResponse {
        let url = try xrpcURL(nsid, query: query)
        return try await perform(HTTPRequest(method: "GET", url: url))
    }

    private func post<Body: Encodable>(_ nsid: String, body: Body) async throws -> HTTPResponse {
        let url = try xrpcURL(nsid, query: [])
        // No date strategy on purpose: record types format their own dates
        // as ATProto wants them (RFC 3339 with fractional seconds and `Z`).
        let data = try JSONEncoder().encode(body)
        return try await perform(HTTPRequest.json(url: url, body: data))
    }

    /// Sends `request` with auth headers, handling the nonce and token
    /// retries described on the type. `request` must not already carry
    /// `Authorization` or `DPoP`; those are added here.
    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        if session.isExpired() {
            try await refreshSession()
        }

        var response = try await sendSigned(request)
        var retriedWithNonce = false
        var refreshedToken = false

        while response.statusCode == 401 {
            if !retriedWithNonce, PDSClient.wantsNonce(response) {
                // sendSigned already recorded the nonce from the 401.
                retriedWithNonce = true
                response = try await sendSigned(request)
            } else if !refreshedToken, PDSClient.rejectedToken(response) {
                refreshedToken = true
                try await refreshSession()
                response = try await sendSigned(request)
            } else {
                break
            }
        }

        guard response.isSuccess else {
            throw PDSClient.serverError(response)
        }
        return response
    }

    private func sendSigned(_ request: HTTPRequest) async throws -> HTTPResponse {
        let origin = request.url.originKey
        let signer = try DPoPProofSigner(rawRepresentation: session.dpopPrivateKey)
        let proof = try signer.proof(
            method: request.method,
            url: request.url,
            nonce: nonces[origin],
            accessToken: session.accessToken
        )

        var signed = request
        signed.headers["Authorization"] = "DPoP \(session.accessToken)"
        signed.headers["DPoP"] = proof
        if signed.headers["Accept"] == nil {
            signed.headers["Accept"] = "application/json"
        }

        let response = try await http.send(signed)
        if let nonce = response.header("DPoP-Nonce"), !nonce.isEmpty {
            nonces[origin] = nonce
        }
        return response
    }

    private func refreshSession() async throws {
        let refreshed = try await oauth.refresh(session)
        // Update ourselves first: the old refresh token is already spent, so
        // even if persisting fails this process can keep going.
        session = refreshed
        try sessionStore.save(refreshed)
    }

    // MARK: - Response inspection

    /// A 401 asking for a DPoP nonce, per RFC 9449 §8: `WWW-Authenticate`
    /// names `use_dpop_nonce` (ATProto PDSs also put it in the JSON body)
    /// and a `DPoP-Nonce` header carries the nonce to use.
    private static func wantsNonce(_ response: HTTPResponse) -> Bool {
        guard let nonce = response.header("DPoP-Nonce"), !nonce.isEmpty else { return false }
        if response.header("WWW-Authenticate")?.contains("use_dpop_nonce") == true {
            return true
        }
        return errorBody(response)?.error == "use_dpop_nonce"
    }

    /// A 401 saying the access token itself is no good.
    private static func rejectedToken(_ response: HTTPResponse) -> Bool {
        let rejectedCodes: Set<String> = ["invalid_token", "ExpiredToken", "InvalidToken"]
        if let code = errorBody(response)?.error, rejectedCodes.contains(code) {
            return true
        }
        if let challenge = response.header("WWW-Authenticate"), challenge.contains("invalid_token") {
            return true
        }
        return false
    }

    private static func errorBody(_ response: HTTPResponse) -> XRPCErrorBody? {
        try? response.decode(XRPCErrorBody.self)
    }

    private static func serverError(_ response: HTTPResponse) -> XRPCError {
        let body = errorBody(response)
        return .server(status: response.statusCode, error: body?.error, message: body?.message)
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
        guard var components = URLComponents(url: session.pdsURL, resolvingAgainstBaseURL: false) else {
            throw XRPCError.invalidURL(session.pdsURL.absoluteString)
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
            throw XRPCError.invalidURL(session.pdsURL.absoluteString)
        }
        return url
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
