import XCTest
import Foundation
import OsaurusPluginKit
@testable import osaurus_music

final class MusicTests: XCTestCase {

    private func parseManifest() throws -> [String: Any] {
        let data = Data(musicManifestJSON.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw XCTSkip("Manifest is not a JSON object")
        }
        return dict
    }

    private func manifestTools() throws -> [[String: Any]] {
        let manifest = try parseManifest()
        guard let capabilities = manifest["capabilities"] as? [String: Any],
              let tools = capabilities["tools"] as? [[String: Any]] else {
            XCTFail("Manifest missing capabilities.tools array")
            return []
        }
        return tools
    }

    func testManifestIsValidJSON() throws {
        let manifest = try parseManifest()
        XCTAssertEqual(manifest["plugin_id"] as? String, "osaurus.music")
        XCTAssertEqual(manifest["version"] as? String, "1.1.0")
    }

    func testManifestHasThirteenToolsWithIdAndDescription() throws {
        let tools = try manifestTools()
        XCTAssertEqual(tools.count, 13, "Expected exactly 13 tools in the manifest")

        for tool in tools {
            let id = tool["id"] as? String
            XCTAssertNotNil(id, "Every tool must have an 'id'")
            XCTAssertFalse((id ?? "").isEmpty, "Tool 'id' must be non-empty")

            let description = tool["description"] as? String
            XCTAssertNotNil(description, "Tool \(id ?? "?") must have a 'description'")
            XCTAssertFalse((description ?? "").isEmpty, "Tool \(id ?? "?") 'description' must be non-empty")
        }
    }

    func testManifestToolIdsMatchRegisteredTools() throws {
        let tools = try manifestTools()
        let manifestIDs = Set(tools.compactMap { $0["id"] as? String })
        let registeredIDs = Set(PluginContext().tools.keys)

        XCTAssertEqual(
            manifestIDs,
            registeredIDs,
            "Manifest tool ids must exactly match the registered tool implementations"
        )
        XCTAssertEqual(registeredIDs.count, 13, "Expected exactly 13 registered tools")
    }

    func testEnvelopeFailureRoundTrip() throws {
        let message = "Quote \" and backslash \\ and newline \n end"
        let json = Envelope.failure(.invalidArgs, message)

        let data = Data(json.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            return XCTFail("Failure envelope is not a JSON object")
        }

        XCTAssertEqual(dict["ok"] as? Bool, false)
        XCTAssertEqual(dict["kind"] as? String, "invalid_args")
        XCTAssertEqual(dict["message"] as? String, message)
        // invalid_args is deterministic — retrying the same arguments cannot succeed
        XCTAssertEqual(dict["retryable"] as? Bool, false)
    }

    func testEnvelopeDefaultRetryablePerKind() throws {
        func decode(_ json: String) throws -> [String: Any] {
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
            return try XCTUnwrap(object as? [String: Any])
        }

        XCTAssertEqual(try decode(Envelope.failure(.invalidArgs, "x"))["retryable"] as? Bool, false)
        XCTAssertEqual(try decode(Envelope.failure(.executionError, "x"))["retryable"] as? Bool, true)
        XCTAssertEqual(try decode(Envelope.failure(.unavailable, "x"))["retryable"] as? Bool, true)
        XCTAssertEqual(try decode(Envelope.failure(.timeout, "x"))["retryable"] as? Bool, true)
        XCTAssertEqual(try decode(Envelope.failure(.notFound, "x"))["retryable"] as? Bool, false)

        // Explicit override is honored (permission/not-running uses unavailable + retryable:false).
        XCTAssertEqual(
            try decode(Envelope.failure(.unavailable, "x", retryable: false))["retryable"] as? Bool,
            false
        )
    }
}
