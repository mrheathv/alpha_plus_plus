import Foundation
@testable import AlphaPlusPlus

/// **Every track, created once per test run.**
///
/// The soundtrack suites asked `Soundtrack.render` for the same tracks over
/// and over — fourteen call sites, most of them looping over the whole
/// library — and in a Debug build that one function was about 480 of the
/// suite's 1,400 seconds. A track is a pure function of its score, so
/// creating it once and handing every test the same buffer asks exactly the
/// same questions of exactly the same audio.
///
/// **Not for a test that times rendering**, which has to render for real —
/// `SoundtrackPlayerTests.testMeasureWhatRenderingTheLibraryCosts` still calls
/// `Soundtrack.render` directly, and is opt-in for that reason (`TestReports`).
///
/// Locked rather than `@MainActor`, because the soundtrack tests are not main
/// actor bound and XCTest may run them on any thread.
enum RenderedTracks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Soundtrack.Buffer] = [:]

    static func mix(_ track: Track) -> Soundtrack.Buffer {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[track.name] { return hit }
        let buffer = Soundtrack.render(track)
        cache[track.name] = buffer
        return buffer
    }
}

/// **Tests that report rather than check**, run only when asked.
///
/// A handful of tests exist to print a number or write a file for a person to
/// read — a spectrum, a render cost, a WAV — and assert little or nothing.
/// They are worth having and not worth paying for on every run: measured, four
/// of them were a sixth of the whole suite's time. Opt in with
/// `TEST_RUNNER_REPORTS=1` (xcodebuild forwards only `TEST_RUNNER_`-prefixed
/// variables, and strips the prefix), or with the full playtest profile,
/// which is already the "I am here to read numbers" switch.
enum TestReports {
    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["REPORTS"] != nil || environment["PLAYTEST_FULL"] != nil
    }

    static let skipReason = "a readout, not a check — run with TEST_RUNNER_REPORTS=1"
}
