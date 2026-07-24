import OsaurusPluginKit
import OsaurusPluginTestSupport
import XCTest

@testable import osaurus_music

final class SDKConformanceTests: XCTestCase {

    func testManifestPassesSDKRegistryConformance() throws {
        try ManifestConformance.assertConformant(musicManifestJSON)
    }

    func testV2EntryPointReturnsConformantPluginAPI() throws {
        try ABIConformance.assertEntryConformance(
            osaurus_plugin_entry_v2(nil), manifestJSON: musicManifestJSON)
    }

    func testV1EntryPointReturnsConformantPluginAPI() throws {
        try ABIConformance.assertEntryConformance(
            osaurus_plugin_entry(), manifestJSON: musicManifestJSON)
    }

    func testInvalidArgsFailureIsCanonical() throws {
        let json = PluginContext().invoke(toolId: "set_volume", payload: "{\"level\": 500}")
        try assertCanonicalFailure(json, kind: .invalidArgs)
    }
}
