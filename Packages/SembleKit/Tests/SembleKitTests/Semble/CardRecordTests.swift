import Foundation
import XCTest
@testable import SembleKit

final class CardRecordTests: XCTestCase {
    private let configuration = SembleConfiguration.production
    private let link = URL(string: "https://example.com/post?id=1&ref=share")!
    // 2023-11-14T22:13:20.500Z
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000.5)

    private func encodeToJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testURLCardKeepsTheURLInsideContentOnly() throws {
        let record = CardRecord.url(link, preview: nil, createdAt: fixedDate, configuration: configuration)
        let json = try encodeToJSON(record)

        XCTAssertEqual(json["$type"] as? String, "network.cosmik.card")
        XCTAssertEqual(json["type"] as? String, "URL")
        XCTAssertNil(json["url"], "URL cards carry their URL in content, not at the top level")
        XCTAssertNil(json["parentCard"])

        let content = try XCTUnwrap(json["content"] as? [String: Any])
        XCTAssertEqual(content["$type"] as? String, "network.cosmik.card#urlContent")
        XCTAssertEqual(content["url"] as? String, link.absoluteString)
        XCTAssertNil(content["metadata"], "no preview means no metadata object")
    }

    func testURLCardWritesPreviewAsMetadata() throws {
        let preview = URLPreview(
            url: link,
            title: "A post",
            description: "About things",
            siteName: "Example",
            type: "article",
            imageURL: URL(string: "https://example.com/image.png")
        )
        let record = CardRecord.url(link, preview: preview, createdAt: fixedDate, configuration: configuration)
        let json = try encodeToJSON(record)

        let content = try XCTUnwrap(json["content"] as? [String: Any])
        let metadata = try XCTUnwrap(content["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["$type"] as? String, "network.cosmik.card#urlMetadata")
        XCTAssertEqual(metadata["title"] as? String, "A post")
        XCTAssertEqual(metadata["description"] as? String, "About things")
        XCTAssertEqual(metadata["siteName"] as? String, "Example")
        XCTAssertEqual(metadata["type"] as? String, "article")
        XCTAssertEqual(metadata["imageUrl"] as? String, "https://example.com/image.png")
        XCTAssertEqual(metadata["retrievedAt"] as? String, "2023-11-14T22:13:20.500Z")
        XCTAssertNil(metadata["author"], "fields the preview doesn't have are omitted, not null")
    }

    func testNoteCardNamesItsURLAndParent() throws {
        let parent = StrongRef(uri: "at://did:plc:test/network.cosmik.card/1", cid: "bafy1")
        let record = CardRecord.note(text: "Read later", about: link, parent: parent, createdAt: fixedDate, configuration: configuration)
        let json = try encodeToJSON(record)

        XCTAssertEqual(json["$type"] as? String, "network.cosmik.card")
        XCTAssertEqual(json["type"] as? String, "NOTE")
        XCTAssertEqual(json["url"] as? String, link.absoluteString)

        let parentCard = try XCTUnwrap(json["parentCard"] as? [String: Any])
        XCTAssertEqual(parentCard["uri"] as? String, parent.uri)
        XCTAssertEqual(parentCard["cid"] as? String, parent.cid)

        let content = try XCTUnwrap(json["content"] as? [String: Any])
        XCTAssertEqual(content["$type"] as? String, "network.cosmik.card#noteContent")
        XCTAssertEqual(content["text"] as? String, "Read later")
    }

    func testDatesSerialiseAsRFC3339WithMillisecondsAndZ() throws {
        let record = CardRecord.url(link, createdAt: fixedDate, configuration: configuration)
        let json = try encodeToJSON(record)
        let createdAt = try XCTUnwrap(json["createdAt"] as? String)

        XCTAssertEqual(createdAt, "2023-11-14T22:13:20.500Z")
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        XCTAssertNotNil(createdAt.range(of: pattern, options: .regularExpression))

        XCTAssertEqual(ATProtoDateFormatter.string(from: Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
    }

    func testDatesParseWithOrWithoutFractionalSeconds() {
        XCTAssertEqual(ATProtoDateFormatter.date(from: "2023-11-14T22:13:20.500Z"), fixedDate)
        XCTAssertEqual(ATProtoDateFormatter.date(from: "2023-11-14T22:13:20Z"), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(ATProtoDateFormatter.date(from: "yesterday"))
    }

    func testCardRoundTripsThroughJSON() throws {
        let preview = URLPreview(url: link, title: "A post")
        let original = CardRecord.url(link, preview: preview, createdAt: fixedDate, configuration: configuration)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CardRecord.self, from: data)
        XCTAssertEqual(decoded, original)

        let parent = StrongRef(uri: "at://did:plc:test/network.cosmik.card/1", cid: "bafy1")
        let note = CardRecord.note(text: "Hi", about: link, parent: parent, createdAt: fixedDate, configuration: configuration)
        let decodedNote = try JSONDecoder().decode(CardRecord.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(decodedNote, note)
    }

    func testDecodingToleratesUnknownFields() throws {
        // `originalCard` and `provenance` are real lexicon fields we don't
        // model; other clients' extras must not break decoding either.
        let json = """
        {
          "$type": "network.cosmik.card",
          "type": "URL",
          "content": {"$type": "network.cosmik.card#urlContent", "url": "https://example.com", "extra": 1},
          "createdAt": "2023-11-14T22:13:20Z",
          "originalCard": {"uri": "at://x/y/z", "cid": "bafy"},
          "provenance": {"$type": "network.cosmik.defs#provenance", "via": {"uri": "at://x/y/z", "cid": "bafy"}},
          "somethingNew": true
        }
        """
        let record = try JSONDecoder().decode(CardRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.type, .url)
        guard case let .url(content) = record.content else {
            return XCTFail("expected URL content")
        }
        XCTAssertEqual(content.url, "https://example.com")
    }

    func testCollectionRecordShape() throws {
        let record = CollectionRecord(
            name: "Reading",
            description: nil,
            accessType: .closed,
            createdAt: fixedDate,
            updatedAt: fixedDate,
            configuration: configuration
        )
        let json = try encodeToJSON(record)
        XCTAssertEqual(json["$type"] as? String, "network.cosmik.collection")
        XCTAssertEqual(json["name"] as? String, "Reading")
        XCTAssertEqual(json["accessType"] as? String, "CLOSED")
        XCTAssertEqual(json["collaborators"] as? [String], [])
        XCTAssertNil(json["description"])
        XCTAssertEqual(json["createdAt"] as? String, "2023-11-14T22:13:20.500Z")
        XCTAssertEqual(json["updatedAt"] as? String, "2023-11-14T22:13:20.500Z")

        let decoded = try JSONDecoder().decode(CollectionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
    }

    func testCollectionLinkRecordShape() throws {
        let collection = StrongRef(uri: "at://did:plc:test/network.cosmik.collection/7", cid: "bafyc")
        let card = StrongRef(uri: "at://did:plc:test/network.cosmik.card/1", cid: "bafy1")
        let record = CollectionLinkRecord(
            collection: collection,
            card: card,
            addedBy: "did:plc:test",
            addedAt: fixedDate,
            createdAt: fixedDate,
            configuration: configuration
        )
        let json = try encodeToJSON(record)
        XCTAssertEqual(json["$type"] as? String, "network.cosmik.collectionLink")
        XCTAssertEqual((json["collection"] as? [String: Any])?["uri"] as? String, collection.uri)
        XCTAssertEqual((json["card"] as? [String: Any])?["cid"] as? String, card.cid)
        XCTAssertEqual(json["addedBy"] as? String, "did:plc:test")
        XCTAssertEqual(json["addedAt"] as? String, "2023-11-14T22:13:20.500Z")
        XCTAssertEqual(json["createdAt"] as? String, "2023-11-14T22:13:20.500Z")

        let decoded = try JSONDecoder().decode(CollectionLinkRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
    }

    func testTypesFollowTheConfiguredNamespace() throws {
        let staging = SembleConfiguration(
            cardCollection: "network.cosmik.staging.card",
            collectionCollection: "network.cosmik.staging.collection",
            collectionLinkCollection: "network.cosmik.staging.collectionLink",
            apiBaseURL: URL(string: "https://staging.example/xrpc")!,
            websiteURL: URL(string: "https://staging.example")!
        )
        let json = try encodeToJSON(CardRecord.url(link, createdAt: fixedDate, configuration: staging))
        XCTAssertEqual(json["$type"] as? String, "network.cosmik.staging.card")
        XCTAssertEqual((json["content"] as? [String: Any])?["$type"] as? String, "network.cosmik.staging.card#urlContent")
    }
}
