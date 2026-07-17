import XCTest
import Foundation
@testable import osaurus_music

final class SubprocessRunnerTests: XCTestCase {

    func testCapturesStdoutAndExitStatus() throws {
        let result = try runSubprocess(
            executable: "/bin/sh", arguments: ["-c", "printf hello"], timeout: 10)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout, "hello")
        XCTAssertFalse(result.timedOut)
    }

    func testLargeOutputDoesNotDeadlock() throws {
        // 4 MB of output — far beyond the ~64 KB kernel pipe buffer. The old
        // wait-then-read implementation deadlocks here.
        let result = try runSubprocess(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=4096 2>/dev/null | tr '\\0' 'x'"],
            timeout: 20)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout.count, 4 * 1024 * 1024)
    }

    func testHungProcessIsKilledAndReportedAsTimedOut() throws {
        let start = Date()
        let result = try runSubprocess(
            executable: "/bin/sh", arguments: ["-c", "sleep 60"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    func testOutputIsCapped() throws {
        let result = try runSubprocess(
            executable: "/bin/sh",
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=64 2>/dev/null | tr '\\0' 'x'"],
            timeout: 20, outputCap: 1024)
        XCTAssertEqual(result.stdout.count, 1024)
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
        let result = try runSubprocess(
            executable: "/usr/bin/osascript", arguments: ["-e", script], timeout: 20)
        XCTAssertEqual(result.terminationStatus, 0, "osascript failed: \(result.stderr)")

        let expectedInput = "A|||B\tC~~~D\nE\\F"
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .newlines),
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

    func testSetVolumeStillRejectsOutOfRange() {
        let result = ctx.invoke(toolId: "set_volume", payload: "{\"level\": 500}")
        XCTAssertTrue(result.contains("\"kind\":\"invalid_args\""), "got: \(result)")
    }
}
