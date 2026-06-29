import Foundation

// MARK: - AppleScript Runner

struct AppleScriptRunner {
    enum RunnerError: Error {
        case musicNotRunning
        case permissionDenied
        case executionFailed(String)

        /// Canonical failure envelope for this error. Permission/not-running map to
        /// `unavailable` with `retryable: false`; other failures map to `execution_error`.
        var jsonError: String {
            switch self {
            case .musicNotRunning:
                return Envelope.failure(.unavailable, "Music app is not running. Please open Apple Music first.", retryable: false)
            case .permissionDenied:
                return Envelope.failure(.unavailable, "Automation permission denied. Grant Osaurus access in System Settings > Privacy & Security > Automation.", retryable: false)
            case .executionFailed(let message):
                return Envelope.failure(.executionError, "Command failed: \(message)")
            }
        }
    }
    
    func isMusicRunning() -> Bool {
        let script = #"tell application "System Events" to (name of processes) contains "Music""#
        return runOsascript(script).output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
    
    func run(_ script: String, requiresMusicRunning: Bool = true) -> Result<String, RunnerError> {
        if requiresMusicRunning && !isMusicRunning() {
            return .failure(.musicNotRunning)
        }
        
        let result = runOsascript(script)
        
        if result.exitCode != 0 {
            let stderr = result.error.lowercased()
            if stderr.contains("not authorized") || stderr.contains("not allowed") {
                return .failure(.permissionDenied)
            }
            if stderr.contains("isn't running") {
                return .failure(.musicNotRunning)
            }
            return .failure(.executionFailed(result.error))
        }
        
        return .success(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    private func runOsascript(_ script: String) -> (output: String, error: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (output, error, process.terminationStatus)
        } catch {
            return ("", error.localizedDescription, 1)
        }
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
            return name of current track & "|||" & artist of current track & "|||" & album of current track & "|||" & duration of current track & "|||" & player position & "|||" & (player state as string)
        end tell
        """
        
        switch runner.run(script) {
        case .success(let output):
            if output == "STOPPED" {
                return #"{"playing": false, "message": "No track is currently playing"}"#
            }
            
            let parts = output.components(separatedBy: "|||")
            guard parts.count >= 6 else {
                return Envelope.failure(.executionError, "Failed to parse track information")
            }
            
            return """
            {"playing": true, "track": {"name": "\(parts[0].escapedForJSON)", "artist": "\(parts[1].escapedForJSON)", "album": "\(parts[2].escapedForJSON)", "duration": \(parts[3]), "position": \(parts[4]), "state": "\(parts[5].escapedForJSON)"}}
            """
            
        case .failure(let error):
            return error.jsonError
        }
    }
}

private struct GetLibraryStatsTool: Tool {
    let name = "get_library_stats"
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        let script = """
        tell application "Music"
            return (count of tracks of library playlist 1) & "|||" & (count of playlists)
        end tell
        """
        
        switch runner.run(script) {
        case .success(let output):
            let parts = output.components(separatedBy: "|||")
            guard parts.count >= 2 else {
                return Envelope.failure(.executionError, "Failed to parse library statistics")
            }
            return #"{"tracks": \#(parts[0]), "playlists": \#(parts[1])}"#
            
        case .failure(let error):
            return error.jsonError
        }
    }
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

        let limit = input.limit ?? 10
        let escapedQuery = input.query.escapedForAppleScript
        
        let script = """
        tell application "Music"
            set searchResults to search library playlist 1 for "\(escapedQuery)" only songs
            set resultList to {}
            repeat with i from 1 to (count of searchResults)
                if i > \(limit) then exit repeat
                set t to item i of searchResults
                set end of resultList to (name of t & "|||" & artist of t & "|||" & album of t)
            end repeat
            set AppleScript's text item delimiters to "~~~"
            return resultList as string
        end tell
        """
        
        switch runner.run(script) {
        case .success(let output):
            if output.isEmpty {
                return #"{"results": [], "count": 0}"#
            }
            
            let results = output.components(separatedBy: "~~~").compactMap { track -> String? in
                let parts = track.components(separatedBy: "|||")
                guard parts.count >= 3 else { return nil }
                return #"{"name": "\#(parts[0].escapedForJSON)", "artist": "\#(parts[1].escapedForJSON)", "album": "\#(parts[2].escapedForJSON)"}"#
            }
            
            return #"{"results": [\#(results.joined(separator: ", "))], "count": \#(results.count)}"#
            
        case .failure(let error):
            return error.jsonError
        }
    }
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
                return name of theTrack & "|||" & artist of theTrack & "|||" & (player state as string)
            else
                return "NOT_FOUND"
            end if
        end tell
        """
        
        switch runner.run(script) {
        case .success(let output):
            if output == "NOT_FOUND" {
                return Envelope.failure(.notFound, "No song found matching '\(input.song)'")
            }
            
            let parts = output.components(separatedBy: "|||")
            if parts.count >= 3 {
                let isPlaying = parts[2].lowercased() == "playing"
                if isPlaying {
                    return #"{"success": true, "playing": true, "track": {"name": "\#(parts[0].escapedForJSON)", "artist": "\#(parts[1].escapedForJSON)"}}"#
                } else {
                    return #"{"success": true, "playing": false, "track": {"name": "\#(parts[0].escapedForJSON)", "artist": "\#(parts[1].escapedForJSON)"}, "message": "Track found but streaming playback requires manual start. Press play in Music app or try play_playlist instead."}"#
                }
            }
            return #"{"success": true, "playing": false, "message": "Track found"}"#
            
        case .failure(let error):
            return error.jsonError
        }
    }
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
                return (name of thePlaylist) & "|||" & (count of tracks of thePlaylist) & "|||" & (player state as string)
            on error
                return "NOT_FOUND"
            end try
        end tell
        """
        
        switch runner.run(script) {
        case .success(let output):
            if output == "NOT_FOUND" {
                return Envelope.failure(.notFound, "Playlist '\(input.playlist)' not found")
            }
            
            let parts = output.components(separatedBy: "|||")
            if parts.count >= 3 {
                let isPlaying = parts[2].lowercased() == "playing"
                return #"{"success": true, "playing": \#(isPlaying), "playlist": {"name": "\#(parts[0].escapedForJSON)", "tracks": \#(parts[1])}, "shuffle": \#(shuffleEnabled)}"#
            }
            return #"{"success": true}"#
            
        case .failure(let error):
            return error.jsonError
        }
    }
}

private struct ListPlaylistsTool: Tool {
    let name = "list_playlists"
    
    func run(args: String, runner: AppleScriptRunner) -> String {
        struct Args: Decodable {
            let limit: Int?
        }
        
        let input = (try? JSONDecoder().decode(Args.self, from: args.data(using: .utf8) ?? Data()))
        let limit = input?.limit ?? 25
        
        let script = """
        tell application "Music"
            set playlistNames to {}
            set allPlaylists to user playlists
            repeat with i from 1 to (count of allPlaylists)
                if i > \(limit) then exit repeat
                set end of playlistNames to name of item i of allPlaylists
            end repeat
            set AppleScript's text item delimiters to "~~~"
            return playlistNames as string
        end tell
        """
        
        switch runner.run(script) {
        case .success(let output):
            if output.isEmpty {
                return #"{"playlists": [], "count": 0}"#
            }
            
            let names = output.components(separatedBy: "~~~")
            let jsonNames = names.map { #""\#($0.escapedForJSON)""# }
            return #"{"playlists": [\#(jsonNames.joined(separator: ", "))], "count": \#(names.count)}"#
            
        case .failure(let error):
            return error.jsonError
        }
    }
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

// MARK: - C ABI

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

private struct osr_plugin_api {
    var free_string: (@convention(c) (UnsafePointer<CChar>?) -> Void)?
    var `init`: (@convention(c) () -> osr_plugin_ctx_t?)?
    var destroy: (@convention(c) (osr_plugin_ctx_t?) -> Void)?
    var get_manifest: (@convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?)?
    var invoke: (@convention(c) (osr_plugin_ctx_t?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>?)?
}

private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
    guard let ptr = strdup(s) else { return nil }
    return UnsafePointer(ptr)
}

// MARK: - Manifest

let musicManifestJSON = #"""
{
  "plugin_id": "osaurus.music",
  "name": "Apple Music",
  "version": "0.1.0",
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

nonisolated(unsafe) private var api: osr_plugin_api = {
    var api = osr_plugin_api()
    
    api.free_string = { ptr in
        if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
    }
    
    api.`init` = {
        Unmanaged.passRetained(PluginContext()).toOpaque()
    }
    
    api.destroy = { ctxPtr in
        guard let ctxPtr else { return }
        Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
    }
    
    api.get_manifest = { _ in makeCString(musicManifestJSON) }
    
    api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
        guard let ctxPtr, let typePtr, let idPtr, let payloadPtr else { return nil }
        
        let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let type = String(cString: typePtr)
        let id = String(cString: idPtr)
        let payload = String(cString: payloadPtr)
        
        guard type == "tool" else {
            return makeCString(Envelope.failure(.invalidArgs, "Unknown capability type: \(type)"))
        }
        
        return makeCString(ctx.invoke(toolId: id, payload: payload))
    }
    
    return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
    UnsafeRawPointer(&api)
}
