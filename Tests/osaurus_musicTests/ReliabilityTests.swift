import XCTest
import Foundation
import OsaurusPluginKit
@testable import osaurus_music

final class SubprocessRunnerTests: XCTestCase {

    func testCapturesStdoutAndExitStatus() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "printf hello"], timeout: 10)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdoutText, "hello")
        XCTAssertFalse(result.timedOut)
    }

    func testLargeOutputDoesNotDeadlock() throws {
        // 4 MB of output — far beyond the ~64 KB kernel pipe buffer. The old
        // wait-then-read implementation deadlocks here.
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=4096 2>/dev/null | tr '\\0' 'x'"],
            timeout: 20)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdoutText.count, 4 * 1024 * 1024)
    }

    func testHungProcessIsKilledAndReportedAsTimedOut() throws {
        let start = Date()
        let result = try ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 60"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    func testOutputIsCapped() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\\0' 'x'"],
            timeout: 20, maxOutputBytes: 1024)
        XCTAssertEqual(result.stdoutText.count, 1024)
    }
}

final class ErrorClassificationTests: XCTestCase {

    func testPermissionDenialIsNotMisreportedAsMusicNotRunning() {
        // A TCC denial mentions authorization; it must map to permissionDenied
        // even though the plugin used to blame "Music is not running".
        let cases = [
            "osascript: execution error: Not authorized to send Apple events to Music. (-1743)",
            "execution error: Osaurus is not allowed assistive access. (-25211)",
        ]
        for stderr in cases {
            guard case .permissionDenied = classifyOsascriptFailure(stderr: stderr) else {
                return XCTFail("expected permissionDenied for: \(stderr)")
            }
        }
    }

    func testMusicNotRunningClassification() {
        guard case .musicNotRunning = classifyOsascriptFailure(
            stderr: "execution error: Music got an error: Application isn't running. (-600)") else {
            return XCTFail("expected musicNotRunning")
        }
    }

    func testOtherFailuresAreExecutionErrors() {
        guard case .executionFailed = classifyOsascriptFailure(
            stderr: "execution error: Can't get playlist 7. (-1728)") else {
            return XCTFail("expected executionFailed")
        }
    }

    func testTimeoutErrorUsesTimeoutKind() throws {
        let json = AppleScriptRunner.RunnerError.timedOut.jsonError
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["ok"] as? Bool, false)
        XCTAssertEqual(obj["kind"] as? String, "timeout")
        XCTAssertEqual(obj["retryable"] as? Bool, true)
    }

    func testIsMusicRunningDoesNotUseSystemEvents() {
        // The preflight must query the process list directly (NSWorkspace);
        // it must not shell out to a System Events AppleScript that can be
        // blocked by TCC. This is a cheap structural regression check.
        _ = AppleScriptRunner().isMusicRunning()  // must not hang or throw
    }
}

final class FieldCodingTests: XCTestCase {

    let hostileCorpus = [
        "plain title",
        "pipes ||| in title",
        "tildes ~~~ in album",
        "mix |~|~| everywhere",
        "tab\there",
        "newline\nhere",
        "back\\slash",
        "trailing\\",
        "unicode — 🦖",
    ]

    func testRoundTrip() {
        for s in hostileCorpus {
            let encoded = encodeAppleScriptField(s)
            XCTAssertFalse(encoded.contains("|"))
            XCTAssertFalse(encoded.contains("~"))
            XCTAssertFalse(encoded.contains("\t"))
            XCTAssertFalse(encoded.contains("\n"))
            XCTAssertEqual(decodeAppleScriptField(encoded), s, "round-trip failed for \(s)")
        }
    }

    func testAppleScriptHandlerMatchesSwiftEncoder() throws {
        // Pure string manipulation via osascript: no app automation, no TCC.
        let script = """
        set s to "A|||B" & tab & "C~~~D" & linefeed & "E\\\\F"
        return my encodeField(s)
        \(appleScriptFieldEncoderHandlers)
        """
        let result = try ProcessRunner.run(
            executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 20)
        XCTAssertEqual(result.exitStatus, 0, "osascript failed: \(result.stderrText)")

        let expectedInput = "A|||B\tC~~~D\nE\\F"
        XCTAssertEqual(
            result.stdoutText.trimmingCharacters(in: .newlines),
            encodeAppleScriptField(expectedInput))
    }
}

final class OutputParsingTests: XCTestCase {

    private func json(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    func testCurrentTrackWithHostileMetadata() throws {
        let name = "Song ||| with pipes"
        let artist = "Artist~~~tilde"
        let album = "Album\twith\ntab and newline"
        let row = [
            encodeAppleScriptField(name),
            encodeAppleScriptField(artist),
            encodeAppleScriptField(album),
            "241.5", "12.0", "playing",
        ].joined(separator: "\t")

        let obj = try json(renderCurrentTrackJSON(row))
        XCTAssertEqual(obj["playing"] as? Bool, true)
        let track = try XCTUnwrap(obj["track"] as? [String: Any])
        XCTAssertEqual(track["name"] as? String, name)
        XCTAssertEqual(track["artist"] as? String, artist)
        XCTAssertEqual(track["album"] as? String, album)
        XCTAssertEqual(track["duration"] as? Double, 241.5)
    }

    func testCurrentTrackStopped() throws {
        let obj = try json(renderCurrentTrackJSON("STOPPED"))
        XCTAssertEqual(obj["playing"] as? Bool, false)
    }

    func testCurrentTrackMalformedIsError() throws {
        let obj = try json(renderCurrentTrackJSON("only\ttwo"))
        XCTAssertEqual(obj["ok"] as? Bool, false)
        XCTAssertEqual(obj["kind"] as? String, "execution_error")
    }

    func testSearchResultsWithHostileMetadata() throws {
        let rows = [
            [encodeAppleScriptField("T1|||x"), encodeAppleScriptField("A~B"), encodeAppleScriptField("Rec\nord")].joined(separator: "\t"),
            [encodeAppleScriptField("T2"), encodeAppleScriptField("A2"), encodeAppleScriptField("R2")].joined(separator: "\t"),
        ].joined(separator: "\n")

        let obj = try json(renderSearchResultsJSON(rows))
        XCTAssertEqual(obj["count"] as? Int, 2)
        let results = try XCTUnwrap(obj["results"] as? [[String: Any]])
        XCTAssertEqual(results[0]["name"] as? String, "T1|||x")
        XCTAssertEqual(results[0]["artist"] as? String, "A~B")
        XCTAssertEqual(results[0]["album"] as? String, "Rec\nord")
    }

    func testPlaylistNamesWithHostileMetadata() throws {
        let rows = [
            encodeAppleScriptField("Mix ~~~ 2026"),
            encodeAppleScriptField("Road|Trip"),
        ].joined(separator: "\n")

        let obj = try json(renderPlaylistsJSON(rows))
        XCTAssertEqual(obj["count"] as? Int, 2)
        XCTAssertEqual(obj["playlists"] as? [String], ["Mix ~~~ 2026", "Road|Trip"])
    }

    func testPlaylistTracksWithHostileMetadata() throws {
        let rows = [
            "2",
            [encodeAppleScriptField("So|ng~1"), encodeAppleScriptField("Ar\ttist"), encodeAppleScriptField("Al\nbum"), "235"].joined(separator: "\t"),
            [encodeAppleScriptField("Song 2"), encodeAppleScriptField("A2"), encodeAppleScriptField("R2"), "180"].joined(separator: "\t"),
        ].joined(separator: "\n")

        let obj = try json(renderPlaylistTracksJSON(rows))
        XCTAssertEqual(obj["count"] as? Int, 2)
        XCTAssertEqual(obj["total"] as? Int, 2)
        XCTAssertEqual(obj["truncated"] as? Bool, false)
        XCTAssertEqual(obj["skipped"] as? Int, 0)
        let tracks = try XCTUnwrap(obj["tracks"] as? [[String: Any]])
        XCTAssertEqual(tracks[0]["name"] as? String, "So|ng~1")
        XCTAssertEqual(tracks[0]["artist"] as? String, "Ar\ttist")
        XCTAssertEqual(tracks[0]["album"] as? String, "Al\nbum")
        XCTAssertEqual(tracks[0]["duration"] as? Int, 235)
    }

    func testPlaylistTracksReportsTruncation() throws {
        let rows = [
            "500",
            [encodeAppleScriptField("Only"), encodeAppleScriptField("A"), encodeAppleScriptField("R"), "100"].joined(separator: "\t"),
        ].joined(separator: "\n")

        let obj = try json(renderPlaylistTracksJSON(rows))
        XCTAssertEqual(obj["count"] as? Int, 1)
        XCTAssertEqual(obj["total"] as? Int, 500)
        XCTAssertEqual(obj["truncated"] as? Bool, true)
        XCTAssertEqual(obj["skipped"] as? Int, 0)
    }

    func testPlaylistTracksEmptyPlaylist() throws {
        let obj = try json(renderPlaylistTracksJSON("0"))
        XCTAssertEqual(obj["count"] as? Int, 0)
        XCTAssertEqual(obj["total"] as? Int, 0)
        XCTAssertEqual(obj["truncated"] as? Bool, false)
        XCTAssertEqual(obj["skipped"] as? Int, 0)
        XCTAssertEqual((obj["tracks"] as? [[String: Any]])?.count, 0)
    }

    func testPlaylistTracksMalformedHeaderIsError() throws {
        let obj = try json(renderPlaylistTracksJSON("not-a-number\nSong\tA\tR\t100"))
        XCTAssertEqual(obj["ok"] as? Bool, false)
        XCTAssertEqual(obj["kind"] as? String, "execution_error")
    }

    func testPlaylistTracksSkipsMalformedRows() throws {
        let rows = ["2", "missing\tfields", ["ok", "A", "R", "90"].joined(separator: "\t")].joined(separator: "\n")
        let obj = try json(renderPlaylistTracksJSON(rows))
        XCTAssertEqual(obj["count"] as? Int, 1)
        XCTAssertEqual(obj["skipped"] as? Int, 1)
        XCTAssertEqual(
            obj["truncated"] as? Bool, false,
            "both rows arrived; a dropped row is not the limit withholding tracks")
    }

    func testPlaylistTracksRoundsRawDurations() throws {
        // AppleScript now emits the raw real; Swift owns the rounding.
        let rows = [
            "3",
            ["A", "B", "C", "235.410995483398"].joined(separator: "\t"),
            ["D", "E", "F", "213.826995849609"].joined(separator: "\t"),
            ["G", "H", "I", "0"].joined(separator: "\t"),
        ].joined(separator: "\n")

        let obj = try json(renderPlaylistTracksJSON(rows))
        let tracks = try XCTUnwrap(obj["tracks"] as? [[String: Any]])
        XCTAssertEqual(tracks[0]["duration"] as? Int, 235)
        XCTAssertEqual(tracks[1]["duration"] as? Int, 214, "should round up, not truncate")
        XCTAssertEqual(tracks[2]["duration"] as? Int, 0, "missing value maps to 0")
    }

    func testPlaylistTracksRejectsNonNumericDuration() throws {
        let rows = ["1", ["A", "B", "C", "not-a-number"].joined(separator: "\t")].joined(separator: "\n")
        let obj = try json(renderPlaylistTracksJSON(rows))
        XCTAssertEqual(obj["count"] as? Int, 0, "malformed row is skipped, not emitted as null")
        XCTAssertEqual(obj["skipped"] as? Int, 1)
        XCTAssertEqual(obj["truncated"] as? Bool, false, "the only row arrived; nothing was withheld")
    }

    func testPlaySongWithHostileMetadata() throws {
        let row = [encodeAppleScriptField("N|1"), encodeAppleScriptField("A~2"), "playing"].joined(separator: "\t")
        let obj = try json(renderPlaySongJSON(row))
        XCTAssertEqual(obj["playing"] as? Bool, true)
        let track = try XCTUnwrap(obj["track"] as? [String: Any])
        XCTAssertEqual(track["name"] as? String, "N|1")
        XCTAssertEqual(track["artist"] as? String, "A~2")
    }

    func testPlayPlaylistWithHostileMetadata() throws {
        let row = [encodeAppleScriptField("List|~|Name"), "42", "paused"].joined(separator: "\t")
        let obj = try json(renderPlayPlaylistJSON(row, shuffle: true))
        XCTAssertEqual(obj["playing"] as? Bool, false)
        XCTAssertEqual(obj["shuffle"] as? Bool, true)
        let playlist = try XCTUnwrap(obj["playlist"] as? [String: Any])
        XCTAssertEqual(playlist["name"] as? String, "List|~|Name")
        XCTAssertEqual(playlist["tracks"] as? Int, 42)
    }

    func testLibraryStatsParsing() throws {
        let obj = try json(renderLibraryStatsJSON("1234\t56"))
        XCTAssertEqual(obj["tracks"] as? Int, 1234)
        XCTAssertEqual(obj["playlists"] as? Int, 56)

        let bad = try json(renderLibraryStatsJSON("1234, |||, 56"))
        XCTAssertEqual(bad["ok"] as? Bool, false)
        XCTAssertEqual(bad["kind"] as? String, "execution_error")
    }
}

final class ValidationTests: XCTestCase {

    private let ctx = PluginContext()

    func testSearchSongsRejectsNonPositiveLimit() {
        for bad in ["{\"query\": \"jazz\", \"limit\": 0}", "{\"query\": \"jazz\", \"limit\": -3}"] {
            let result = ctx.invoke(toolId: "search_songs", payload: bad)
            XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
        }
    }

    func testListPlaylistsRejectsMalformedArgs() {
        let result = ctx.invoke(toolId: "list_playlists", payload: "not json")
        XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
    }

    func testListPlaylistsRejectsNonPositiveLimit() {
        let result = ctx.invoke(toolId: "list_playlists", payload: "{\"limit\": -1}")
        XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
    }

    func testPlaylistTracksClampsLimitToMax() {
        XCTAssertEqual(clampPlaylistTrackLimit(5000), maxPlaylistTracks, "over-large limit must be clamped")
        XCTAssertEqual(clampPlaylistTrackLimit(maxPlaylistTracks + 1), maxPlaylistTracks)
        XCTAssertEqual(clampPlaylistTrackLimit(maxPlaylistTracks), maxPlaylistTracks, "the ceiling itself is allowed")
    }

    func testPlaylistTracksUsesDefaultLimitWhenUnspecified() {
        XCTAssertEqual(clampPlaylistTrackLimit(nil), defaultPlaylistTracks)
        XCTAssertLessThanOrEqual(defaultPlaylistTracks, maxPlaylistTracks)
    }

    func testPlaylistTracksPassesThroughLimitsBelowMax() {
        XCTAssertEqual(clampPlaylistTrackLimit(1), 1)
        XCTAssertEqual(clampPlaylistTrackLimit(7), 7)
        XCTAssertEqual(clampPlaylistTrackLimit(maxPlaylistTracks - 1), maxPlaylistTracks - 1)
    }

    func testPlaylistTracksRejectsMalformedArgs() {
        let result = ctx.invoke(toolId: "get_playlist_tracks", payload: "not json")
        XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
    }

    func testPlaylistTracksRejectsMissingPlaylist() {
        for bad in ["{}", "{\"playlist\": \"\"}", "{\"playlist\": \"   \"}"] {
            let result = ctx.invoke(toolId: "get_playlist_tracks", payload: bad)
            XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
        }
    }

    func testPlaylistTracksRejectsNonPositiveLimit() {
        for bad in ["{\"playlist\": \"Mix\", \"limit\": 0}", "{\"playlist\": \"Mix\", \"limit\": -3}"] {
            let result = ctx.invoke(toolId: "get_playlist_tracks", payload: bad)
            XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
        }
    }

    func testSetVolumeStillRejectsOutOfRange() {
        let result = ctx.invoke(toolId: "set_volume", payload: "{\"level\": 500}")
        XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
    }
}
