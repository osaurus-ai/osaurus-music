import AppKit
import Foundation
import OsaurusPluginABI
import OsaurusPluginKit

// MARK: - AppleScript Runner

/// How long an osascript invocation may run before it is killed.
let appleScriptTimeoutSeconds: TimeInterval = 30

/// Classify a nonzero-exit osascript stderr into a runner error. Permission
/// denials are checked first so a TCC denial is never misreported as
/// "Music is not running".
func classifyOsascriptFailure(stderr: String) -> AppleScriptRunner.RunnerError {
    let lower = stderr.lowercased()
    if lower.contains("not authorized") || lower.contains("not allowed")
        || lower.contains("-1743") || lower.contains("permission") {
        return .permissionDenied
    }
    if lower.contains("isn't running") || lower.contains("is not running") || lower.contains("-600") {
        return .musicNotRunning
    }
    return .executionFailed(stderr)
}

struct AppleScriptRunner {
    enum RunnerError: Error {
        case musicNotRunning
        case permissionDenied
        case timedOut
        case executionFailed(String)

        /// Canonical failure envelope for this error. Permission/not-running map to
        /// `unavailable` with `retryable: false`; timeouts map to `timeout`; other
        /// failures map to `execution_error`.
        var jsonError: String {
            switch self {
            case .musicNotRunning:
                return Envelope.failure(.unavailable, "Music app is not running. Please open Apple Music first.", retryable: false)
            case .permissionDenied:
                return Envelope.failure(.unavailable, "Automation permission denied. Grant Osaurus access in System Settings > Privacy & Security > Automation.", retryable: false)
            case .timedOut:
                return Envelope.failure(.timeout, "Music did not respond within \(Int(appleScriptTimeoutSeconds)) seconds and the command was cancelled. Try again.")
            case .executionFailed(let message):
                return Envelope.failure(.executionError, "Command failed: \(message)")
            }
        }
    }

    /// Whether Music.app is running. Queries the process list directly via
    /// NSWorkspace: no Apple Events and no TCC involved, so a System Events
    /// automation denial can no longer be misreported as "Music is not running".
    func isMusicRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.Music"
        }
    }

    func run(_ script: String, requiresMusicRunning: Bool = true) -> Result<String, RunnerError> {
        if requiresMusicRunning && !isMusicRunning() {
            return .failure(.musicNotRunning)
        }

        let result: ProcessRunner.Output
        do {
            result = try ProcessRunner.run(
                executable: "/usr/bin/osascript", arguments: ["-e", script],
                timeout: appleScriptTimeoutSeconds)
        } catch {
            return .failure(.executionFailed("Failed to launch osascript: \(error.localizedDescription)"))
        }

        if result.timedOut {
            return .failure(.timedOut)
        }

        if result.exitStatus != 0 {
            return .failure(classifyOsascriptFailure(stderr: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return .success(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - JSON Helpers

private extension String {
    var escapedForJSON: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// Escapes a string for safe interpolation inside an AppleScript string literal.
    /// Backslash must be escaped first so we don't double-escape the quotes we add.
    var escapedForAppleScript: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Tool Protocol

protocol Tool {
    var name: String { get }
    func run(args: String, runner: AppleScriptRunner) -> String
}

// MARK: - Simple Command Tool

/// A tool that runs a simple AppleScript command and returns a success message
private struct SimpleCommandTool: Tool {
    let name: String
    let script: String
    let successMessage: String
    let requiresMusicRunning: Bool
    
    init(_ name: String, script: String, message: String, requiresMusicRunning: Bool = true) {
        self.name = name
        self.script = script
        self.successMessage = message
        self.requiresMusicRunning = requiresMusicRunning
    }
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        switch runner.run(script, requiresMusicRunning: requiresMusicRunning) {
        case .success:
            return #"{"success": true, "message": "\#(successMessage)"}"#
        case .failure(let error):
            return error.jsonError
        }
    }
}

// MARK: - Playback Tools

private struct SetVolumeTool: Tool {
    let name = "set_volume"
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        struct Args: Decodable { let level: Int }
        
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data) else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Expected: {\"level\": 0-100}")
        }

        guard (0...100).contains(input.level) else {
            return Envelope.failure(.invalidArgs, "Volume level must be between 0 and 100, got \(input.level).")
        }

        let level = input.level
        let script = #"tell application "Music" to set sound volume to \#(level)"#
        
        switch runner.run(script) {
        case .success:
            return #"{"success": true, "volume": \#(level)}"#
        case .failure(let error):
            return error.jsonError
        }
    }
}

// MARK: - Information Tools

private struct GetCurrentTrackTool: Tool {
    let name = "get_current_track"
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        let script = """
        tell application "Music"
            if player state is stopped then return "STOPPED"
            return my encodeField(name of current track) & tab & my encodeField(artist of current track) & tab & my encodeField(album of current track) & tab & duration of current track & tab & player position & tab & (player state as string)
        end tell
        \(appleScriptFieldEncoderHandlers)
        """
        
        switch runner.run(script) {
        case .success(let output):
            return renderCurrentTrackJSON(output)
        case .failure(let error):
            return error.jsonError
        }
    }
}

/// Parse the tab-delimited, field-encoded get_current_track output into JSON.
func renderCurrentTrackJSON(_ output: String) -> String {
    if output == "STOPPED" {
        return #"{"playing": false, "message": "No track is currently playing"}"#
    }

    let parts = output.components(separatedBy: "\t")
    guard parts.count >= 6,
          Double(parts[3]) != nil, Double(parts[4]) != nil else {
        return Envelope.failure(.executionError, "Failed to parse track information")
    }

    return """
    {"playing": true, "track": {"name": "\(decodeAppleScriptField(parts[0]).escapedForJSON)", "artist": "\(decodeAppleScriptField(parts[1]).escapedForJSON)", "album": "\(decodeAppleScriptField(parts[2]).escapedForJSON)", "duration": \(parts[3]), "position": \(parts[4]), "state": "\(parts[5].escapedForJSON)"}}
    """
}

private struct GetLibraryStatsTool: Tool {
    let name = "get_library_stats"
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        let script = """
        tell application "Music"
            return ((count of tracks of library playlist 1) as text) & tab & ((count of playlists) as text)
        end tell
        """
        
        switch runner.run(script) {
        case .success(let output):
            return renderLibraryStatsJSON(output)
        case .failure(let error):
            return error.jsonError
        }
    }
}

/// Parse the tab-delimited get_library_stats output into JSON. Counts are
/// validated as integers so malformed output cannot yield invalid JSON.
func renderLibraryStatsJSON(_ output: String) -> String {
    let parts = output.components(separatedBy: "\t")
    guard parts.count >= 2,
          let tracks = Int(parts[0].trimmingCharacters(in: .whitespaces)),
          let playlists = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
        return Envelope.failure(.executionError, "Failed to parse library statistics")
    }
    return #"{"tracks": \#(tracks), "playlists": \#(playlists)}"#
}

// MARK: - Search Tools

private struct SearchSongsTool: Tool {
    let name = "search_songs"
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        struct Args: Decodable {
            let query: String
            let limit: Int?
        }
        
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data) else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Expected: {\"query\": \"search term\"}")
        }

        guard !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Envelope.failure(.invalidArgs, "Missing required argument 'query'.")
        }

        if let requested = input.limit, requested < 1 {
            return Envelope.failure(.invalidArgs, "'limit' must be a positive integer, got \(requested).")
        }
        let limit = min(input.limit ?? 10, 100)
        let escapedQuery = input.query.escapedForAppleScript
        
        let script = """
        tell application "Music"
            set searchResults to search library playlist 1 for "\(escapedQuery)" only songs
            set output to ""
            repeat with i from 1 to (count of searchResults)
                if i > \(limit) then exit repeat
                set t to item i of searchResults
                set output to output & my encodeField(name of t) & tab & my encodeField(artist of t) & tab & my encodeField(album of t) & linefeed
            end repeat
            return output
        end tell
        \(appleScriptFieldEncoderHandlers)
        """
        
        switch runner.run(script) {
        case .success(let output):
            return renderSearchResultsJSON(output)
        case .failure(let error):
            return error.jsonError
        }
    }
}

/// Parse the linefeed/tab-delimited, field-encoded search_songs output into JSON.
func renderSearchResultsJSON(_ output: String) -> String {
    if output.isEmpty {
        return #"{"results": [], "count": 0}"#
    }

    let results = output.split(separator: "\n").compactMap { track -> String? in
        let parts = track.components(separatedBy: "\t")
        guard parts.count >= 3 else { return nil }
        return #"{"name": "\#(decodeAppleScriptField(parts[0]).escapedForJSON)", "artist": "\#(decodeAppleScriptField(parts[1]).escapedForJSON)", "album": "\#(decodeAppleScriptField(parts[2]).escapedForJSON)"}"#
    }

    return #"{"results": [\#(results.joined(separator: ", "))], "count": \#(results.count)}"#
}

private struct PlaySongTool: Tool {
    let name = "play_song"
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        struct Args: Decodable { let song: String }
        
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data) else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Expected: {\"song\": \"song name\"}")
        }

        guard !input.song.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Envelope.failure(.invalidArgs, "Missing required argument 'song'.")
        }

        let escapedSong = input.song.escapedForAppleScript
        
        let script = """
        tell application "Music"
            activate
            set searchResults to search library playlist 1 for "\(escapedSong)" only songs
            if (count of searchResults) > 0 then
                set theTrack to item 1 of searchResults
                play theTrack
                delay 0.5
                return my encodeField(name of theTrack) & tab & my encodeField(artist of theTrack) & tab & (player state as string)
            else
                return "NOT_FOUND"
            end if
        end tell
        \(appleScriptFieldEncoderHandlers)
        """
        
        switch runner.run(script) {
        case .success(let output):
            if output == "NOT_FOUND" {
                return Envelope.failure(.notFound, "No song found matching '\(input.song)'")
            }
            return renderPlaySongJSON(output)
        case .failure(let error):
            return error.jsonError
        }
    }
}

/// Parse the tab-delimited, field-encoded play_song output into JSON.
func renderPlaySongJSON(_ output: String) -> String {
    let parts = output.components(separatedBy: "\t")
    if parts.count >= 3 {
        let name = decodeAppleScriptField(parts[0]).escapedForJSON
        let artist = decodeAppleScriptField(parts[1]).escapedForJSON
        let isPlaying = parts[2].lowercased() == "playing"
        if isPlaying {
            return #"{"success": true, "playing": true, "track": {"name": "\#(name)", "artist": "\#(artist)"}}"#
        } else {
            return #"{"success": true, "playing": false, "track": {"name": "\#(name)", "artist": "\#(artist)"}, "message": "Track found but streaming playback requires manual start. Press play in Music app or try play_playlist instead."}"#
        }
    }
    return #"{"success": true, "playing": false, "message": "Track found"}"#
}

private struct PlayPlaylistTool: Tool {
    let name = "play_playlist"
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        struct Args: Decodable {
            let playlist: String
            let shuffle: Bool?
        }
        
        guard let data = args.data(using: .utf8),
              let input = try? JSONDecoder().decode(Args.self, from: data) else {
            return Envelope.failure(.invalidArgs, "Invalid arguments. Expected: {\"playlist\": \"playlist name\"}")
        }

        guard !input.playlist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Envelope.failure(.invalidArgs, "Missing required argument 'playlist'.")
        }

        let escapedPlaylist = input.playlist.escapedForAppleScript
        let shuffleEnabled = input.shuffle ?? false
        
        let script = """
        tell application "Music"
            activate
            try
                set thePlaylist to playlist "\(escapedPlaylist)"
                set shuffle enabled to \(shuffleEnabled)
                play thePlaylist
                delay 0.5
                return my encodeField(name of thePlaylist) & tab & ((count of tracks of thePlaylist) as text) & tab & (player state as string)
            on error
                return "NOT_FOUND"
            end try
        end tell
        \(appleScriptFieldEncoderHandlers)
        """
        
        switch runner.run(script) {
        case .success(let output):
            if output == "NOT_FOUND" {
                return Envelope.failure(.notFound, "Playlist '\(input.playlist)' not found")
            }
            return renderPlayPlaylistJSON(output, shuffle: shuffleEnabled)
        case .failure(let error):
            return error.jsonError
        }
    }
}

/// Parse the tab-delimited, field-encoded play_playlist output into JSON.
func renderPlayPlaylistJSON(_ output: String, shuffle: Bool) -> String {
    let parts = output.components(separatedBy: "\t")
    if parts.count >= 3, let trackCount = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
        let isPlaying = parts[2].lowercased() == "playing"
        return #"{"success": true, "playing": \#(isPlaying), "playlist": {"name": "\#(decodeAppleScriptField(parts[0]).escapedForJSON)", "tracks": \#(trackCount)}, "shuffle": \#(shuffle)}"#
    }
    return #"{"success": true}"#
}

private struct ListPlaylistsTool: Tool {
    let name = "list_playlists"
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        struct Args: Decodable {
            let limit: Int?
        }

        var limit = 25
        let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArgs.isEmpty {
            guard let data = trimmedArgs.data(using: .utf8),
                  let input = try? JSONDecoder().decode(Args.self, from: data) else {
                return Envelope.failure(.invalidArgs, "Invalid arguments. Expected: {\"limit\": <positive integer>} or {}")
            }
            if let requested = input.limit {
                guard requested >= 1 else {
                    return Envelope.failure(.invalidArgs, "'limit' must be a positive integer, got \(requested).")
                }
                limit = min(requested, 200)
            }
        }
        
        let script = """
        tell application "Music"
            set output to ""
            set allPlaylists to user playlists
            repeat with i from 1 to (count of allPlaylists)
                if i > \(limit) then exit repeat
                set output to output & my encodeField(name of item i of allPlaylists) & linefeed
            end repeat
            return output
        end tell
        \(appleScriptFieldEncoderHandlers)
        """
        
        switch runner.run(script) {
        case .success(let output):
            return renderPlaylistsJSON(output)
        case .failure(let error):
            return error.jsonError
        }
    }
}

/// Parse the linefeed-delimited, field-encoded list_playlists output into JSON.
func renderPlaylistsJSON(_ output: String) -> String {
    if output.isEmpty {
        return #"{"playlists": [], "count": 0}"#
    }

    let names = output.split(separator: "\n").map { decodeAppleScriptField(String($0)) }
    let jsonNames = names.map { #""\#($0.escapedForJSON)""# }
    return #"{"playlists": [\#(jsonNames.joined(separator: ", "))], "count": \#(names.count)}"#
}

// MARK: - Plugin Context

class PluginContext {
    let runner = AppleScriptRunner()

    let tools: [String: Tool] = {
        let toolList: [Tool] = [
            // Playback controls
            SimpleCommandTool("play", script: #"tell application "Music" to play"#, message: "Playback started"),
            SimpleCommandTool("pause", script: #"tell application "Music" to pause"#, message: "Playback paused"),
            SimpleCommandTool("next_track", script: #"tell application "Music" to next track"#, message: "Skipped to next track"),
            SimpleCommandTool("previous_track", script: #"tell application "Music" to previous track"#, message: "Went to previous track"),
            SimpleCommandTool("open_music", script: #"tell application "Music" to activate"#, message: "Apple Music opened", requiresMusicRunning: false),
            SetVolumeTool(),
            
            // Information
            GetCurrentTrackTool(),
            GetLibraryStatsTool(),
            ListPlaylistsTool(),
            
            // Search
            SearchSongsTool(),
            PlaySongTool(),
            PlayPlaylistTool(),
        ]
        return Dictionary(uniqueKeysWithValues: toolList.map { ($0.name, $0) })
    }()
    
    func invoke(toolId: String, payload: String) -> String {
        guard let tool = tools[toolId] else {
            return Envelope.failure(.notFound, "Unknown tool: \(toolId)")
        }
        return tool.run(args: payload, runner: runner)
    }
}

// MARK: - Manifest

let musicManifestJSON = #"""
{
  "plugin_id": "osaurus.music",
  "name": "Apple Music",
  "version": "1.1.0",
  "description": "Control Apple Music playback, search your library, and get track information",
  "license": "MIT",
  "authors": [],
  "min_macos": "15.0",
  "min_osaurus": "0.5.0",
  "capabilities": {
    "tools": [
      {"id": "open_music", "description": "Open Apple Music app", "parameters": {"type": "object", "properties": {}}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "play", "description": "Resume or start music playback", "parameters": {"type": "object", "properties": {}}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "pause", "description": "Pause music playback", "parameters": {"type": "object", "properties": {}}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "next_track", "description": "Skip to the next track", "parameters": {"type": "object", "properties": {}}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "previous_track", "description": "Go to the previous track", "parameters": {"type": "object", "properties": {}}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "set_volume", "description": "Set volume level (0-100)", "parameters": {"type": "object", "properties": {"level": {"type": "integer", "description": "Volume level from 0 to 100"}}, "required": ["level"]}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "get_current_track", "widget": true, "description": "Get currently playing track info", "parameters": {"type": "object", "properties": {}}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "get_library_stats", "widget": true, "description": "Get library statistics (track and playlist counts)", "parameters": {"type": "object", "properties": {}}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "list_playlists", "widget": true, "description": "List available playlists in the user's library", "parameters": {"type": "object", "properties": {"limit": {"type": "integer", "description": "Max playlists to return (default: 25)"}}}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "search_songs", "description": "Search for songs in your library", "parameters": {"type": "object", "properties": {"query": {"type": "string", "description": "Search query"}, "limit": {"type": "integer", "description": "Max results (default: 10)"}}, "required": ["query"]}, "requirements": ["automation"], "permission_policy": "auto"},
      {"id": "play_song", "description": "Search and play a specific song", "parameters": {"type": "object", "properties": {"song": {"type": "string", "description": "Song name to search and play"}}, "required": ["song"]}, "requirements": ["automation"], "permission_policy": "ask"},
      {"id": "play_playlist", "description": "Play a playlist by name (more reliable than playing individual songs)", "parameters": {"type": "object", "properties": {"playlist": {"type": "string", "description": "Name of the playlist to play"}, "shuffle": {"type": "boolean", "description": "Whether to shuffle the playlist (default: false)"}}, "required": ["playlist"]}, "requirements": ["automation"], "permission_policy": "ask"}
    ]
  }
}
"""#

// MARK: - API Implementation

nonisolated(unsafe) private var pluginAPI = PluginEntry.makeAPI(
    version: OsrABIVersion.v2,
    init: {
        Unmanaged.passRetained(PluginContext()).toOpaque()
    },
    destroy: { ctxPtr in
        guard let ctxPtr else { return }
        Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
    },
    getManifest: { _ in osrMakeCString(musicManifestJSON) },
    invoke: { ctxPtr, typePtr, idPtr, payloadPtr in
        guard let ctxPtr, let typePtr, let idPtr, let payloadPtr else { return nil }

        let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let type = String(cString: typePtr)
        let id = String(cString: idPtr)
        let payload = String(cString: payloadPtr)

        guard type == "tool" else {
            return osrMakeCString(Envelope.failure(.invalidArgs, "Unknown capability type: \(type)"))
        }

        return osrMakeCString(ctx.invoke(toolId: id, payload: payload))
    }
)

// MARK: - Entry Points

/// ABI v2 entry: the host injects its API table, captured into
/// `HostBridge.shared`. Newer hosts try this symbol first.
@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
    PluginEntry.enterV2(host, api: &pluginAPI)
}

/// Legacy ABI v1 entry — kept so old hosts (which never pass a host API)
/// continue to load this plugin.
@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
    PluginEntry.enterV1(api: &pluginAPI)
}
