import Foundation
import Testing

@testable import osaurus_music

@Suite("Plugin Manifest")
struct ManifestTests {

  private enum ManifestError: Error {
    case entryPointFailed
    case nilManifest
    case invalidJSON
  }

  private func loadManifest() throws -> [String: Any] {
    guard let apiPtr = osaurus_plugin_entry() else {
      throw ManifestError.entryPointFailed
    }

    let fnPtrSize = MemoryLayout<UnsafeRawPointer?>.stride
    let initPtr = apiPtr.load(
      fromByteOffset: fnPtrSize,
      as: (@convention(c) () -> UnsafeMutableRawPointer?).self)
    let ctx = initPtr()

    let getManifestPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 3,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?).self)
    guard let cStr = getManifestPtr(ctx) else {
      throw ManifestError.nilManifest
    }
    let jsonString = String(cString: cStr)

    let freeStringPtr = apiPtr.load(
      fromByteOffset: 0,
      as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self)
    freeStringPtr(cStr)

    let destroyPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 2,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    destroyPtr(ctx)

    guard let data = jsonString.data(using: .utf8),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ManifestError.invalidJSON
    }
    return manifest
  }

  private func toolMap(from manifest: [String: Any]) -> [String: [String: Any]] {
    let capabilities = manifest["capabilities"] as? [String: Any]
    let tools = capabilities?["tools"] as? [[String: Any]] ?? []
    return Dictionary(
      uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })
  }

  @Test("manifest has correct plugin identity")
  func pluginIdentity() throws {
    let manifest = try loadManifest()
    #expect(manifest["plugin_id"] as? String == "osaurus.music")
    #expect(manifest["name"] as? String == "Apple Music")
  }

  @Test("manifest declares expected Music tools")
  func toolIDs() throws {
    let map = try toolMap(from: loadManifest())
    #expect(
      Set(map.keys) == [
        "open_music", "play", "pause", "next_track", "previous_track", "set_volume",
        "get_current_track", "get_library_stats", "list_playlists", "search_songs",
        "play_song", "play_playlist",
      ])
  }

  @Test("all tools declare automation requirement")
  func requirements() throws {
    let map = try toolMap(from: loadManifest())
    for (id, tool) in map {
      #expect(tool["requirements"] as? [String] == ["automation"], "Tool '\(id)' requires automation")
    }
  }

  @Test("playback-mutating tools require approval")
  func mutatingToolsAsk() throws {
    let map = try toolMap(from: loadManifest())
    for id in [
      "open_music", "play", "pause", "next_track", "previous_track", "set_volume", "play_song",
      "play_playlist",
    ] {
      #expect(map[id]?["permission_policy"] as? String == "ask", "Tool '\(id)' should ask")
    }
  }

  @Test("library metadata tools can run automatically")
  func metadataToolsAuto() throws {
    let map = try toolMap(from: loadManifest())
    for id in ["get_current_track", "get_library_stats", "list_playlists", "search_songs"] {
      #expect(map[id]?["permission_policy"] as? String == "auto", "Tool '\(id)' should be auto")
    }
  }

  @Test("search and playback tools declare required parameters")
  func requiredParameters() throws {
    let map = try toolMap(from: loadManifest())

    let searchParams = map["search_songs"]?["parameters"] as? [String: Any]
    let searchRequired = searchParams?["required"] as? [String] ?? []
    #expect(searchRequired.contains("query"))

    let volumeParams = map["set_volume"]?["parameters"] as? [String: Any]
    let volumeRequired = volumeParams?["required"] as? [String] ?? []
    #expect(volumeRequired.contains("level"))

    let playlistParams = map["play_playlist"]?["parameters"] as? [String: Any]
    let playlistRequired = playlistParams?["required"] as? [String] ?? []
    #expect(playlistRequired.contains("playlist"))
  }
}
