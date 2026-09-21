import Foundation
import XCTest
@testable import SembleKit

final class URLMetadataClientTests: XCTestCase {
    private let endpoint = "https://api.semble.so/xrpc/network.cosmik.card.getUrlMetadata"
    private let link = URL(string: "https://example.com/post?id=1&ref=share")!

    func testMapsTheMetadataObjectToAPreview() async throws {
        let http = StubHTTPClient()
        http.on(endpoint, json: """
        {
          "metadata": {
            "url": "https://example.com/post?id=1&ref=share",
            "title": "A post",
            "description": "About things",
            "siteName": "Example",
            "imageUrl": "https://example.com/image.png",
            "type": "article",
            "author": "Someone",
            "publishedDate": "2023-11-14T22:13:20.000Z",
            "retrievedAt": "2024-01-01T00:00:00.000Z"
          }
        }
        """)
        let client = URLMetadataClient(http: http)

        let preview = try await client.preview(for: link)

        XCTAssertEqual(preview, URLPreview(
            url: link,
            title: "A post",
            description: "About things",
            siteName: "Example",
            type: "article",
            imageURL: URL(string: "https://example.com/image.png")
        ))
    }

    func testSendsTheURLEncodedAsAQueryParameterWithoutAuth() async throws {
        let http = StubHTTPClient()
        http.on(endpoint, json: #"{"metadata": {"url": "https://example.com/post?id=1&ref=share"}}"#)
        let client = URLMetadataClient(http: http)

        _ = try await client.preview(for: link)

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(request.headers["x-semble-client"], "semble-ios-share")
        let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.semble.so")
        XCTAssertEqual(components.path, "/xrpc/network.cosmik.card.getUrlMetadata")
        // The link's own `?` and `&` must survive as a single `url` value.
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertEqual(components.queryItems?.first?.name, "url")
        XCTAssertEqual(components.queryItems?.first?.value, link.absoluteString)
    }

    func testDropsAnImageURLThatIsNotHTTPS() async throws {
        let http = StubHTTPClient()
        http.on(endpoint, json: """
        {"metadata": {"url": "https://example.com/post?id=1&ref=share", "imageUrl": "http://example.com/image.png"}}
        """)
        let client = URLMetadataClient(http: http)

        let preview = try await client.preview(for: link)

        XCTAssertNil(preview.imageURL)
    }

    func testSendsAShortTimeout() async throws {
        let http = StubHTTPClient()
        http.on(endpoint, json: #"{"metadata": {"url": "https://example.com/post?id=1&ref=share"}}"#)
        let client = URLMetadataClient(http: http)

        _ = try await client.preview(for: link)

        let request = try XCTUnwrap(http.lastRequest)
        XCTAssertEqual(request.timeout, 5)
    }

    func testFallsBackToTheRequestedURLWhenTheResponseHasNone() async throws {
        let http = StubHTTPClient()
        http.on(endpoint, json: #"{"metadata": {"title": "Untitled"}}"#)
        let client = URLMetadataClient(http: http)

        let preview = try await client.preview(for: link)

        XCTAssertEqual(preview.url, link)
        XCTAssertEqual(preview.title, "Untitled")
        XCTAssertNil(preview.imageURL)
    }

    func testAServerErrorIsUnavailable() async {
        let http = StubHTTPClient()
        http.on(endpoint, status: 500, json: #"{"error": "InternalServerError"}"#)
        let client = URLMetadataClient(http: http)

        await assertUnavailable { try await client.preview(for: link) }
    }

    func testAnUndecodableBodyIsUnavailable() async {
        let http = StubHTTPClient()
        http.on(endpoint, json: "<html>not json</html>")
        let client = URLMetadataClient(http: http)

        await assertUnavailable { try await client.preview(for: link) }
    }

    func testATransportFailureIsUnavailable() async {
        let http = StubHTTPClient()
        http.on(endpoint) { _ in throw URLError(.notConnectedToInternet) }
        let client = URLMetadataClient(http: http)

        await assertUnavailable { try await client.preview(for: link) }
    }

    private func assertUnavailable(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> URLPreview
    ) async {
        do {
            _ = try await body()
            XCTFail("expected URLMetadataError.unavailable", file: file, line: line)
        } catch let error as URLMetadataError {
            XCTAssertEqual(error, .unavailable, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - isSafeToPreviewAutomatically

    func testAPlainURLIsSafeToPreviewAutomatically() {
        XCTAssertTrue(URL(string: "https://example.com/article")!.isSafeToPreviewAutomatically)
    }

    func testURLsWithAQueryFragmentOrUserinfoAreNotSafeToPreviewAutomatically() {
        XCTAssertFalse(URL(string: "https://example.com/article?ref=share")!.isSafeToPreviewAutomatically)
        XCTAssertFalse(URL(string: "https://example.com/article#section")!.isSafeToPreviewAutomatically)
        XCTAssertFalse(URL(string: "https://user:pass@example.com/article")!.isSafeToPreviewAutomatically)
    }
}
