import XCTest
@testable import AlphaPlusPlus

/// **The contact sheet for the soundtrack.**
///
/// `ZoneIconContactSheetTests` writes a PNG so a building can be reviewed
/// without playing to it; this writes a WAV so the theme can be heard without
/// launching the game. Same idea, same reason, one medium over — and rather
/// more necessary here, because the author of this code can look at a render
/// and cannot listen to a buffer.
///
/// ```sh
/// xcodebuild -project AlphaPlusPlus.xcodeproj -scheme AlphaPlusPlus \
///            -configuration Debug -derivedDataPath ./build test \
///            -only-testing:AlphaPlusPlusTests/SoundtrackRenderTests
///
/// afplay ./build/Audio/theme.wav
/// ```
final class SoundtrackRenderTests: XCTestCase {

    func testWriteEveryTrackToListenTo() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/Audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Rendered through the profile for the machine this is running on,
        // because a WAV auditioned on a MacBook Air should be the mix a
        // MacBook Air would actually play.
        let profile = AudioProfile.detected()
        print("🔊 \(profile.name) — \(profile.summary)  (\(AudioProfile.currentModel()), \(AudioRoute.current()))")

        for track in MusicLibrary.all {
            let data = Self.wav(profile.apply(to: RenderedTracks.mix(track)))
            let destination = folder.appendingPathComponent("\(track.name).wav")
            try data.write(to: destination)
            print(String(
                format: "🎹 %-12@ %d bars · %3d BPM · %5.1fs · %4d KB — %@",
                track.name as NSString, track.bars, Int(track.beatsPerMinute),
                track.duration, data.count / 1024, track.intent as NSString
            ))
            XCTAssertGreaterThan(data.count, 44, "\(track.name): nothing but a header was written")
        }
    }

    /// Every profile, on the one track whose bass gave the game away, so the
    /// difference can be heard rather than reasoned about.
    func testWriteOneTrackThroughEveryProfile() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/Audio/profiles")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let mix = RenderedTracks.mix(MusicLibrary.smallHours)
        for profile in AudioProfile.all {
            let slug = profile.name.lowercased().replacingOccurrences(of: " ", with: "-")
            let data = Self.wav(profile.apply(to: mix))
            try data.write(to: folder.appendingPathComponent("small-hours-\(slug).wav"))
            print("🔊 \(profile.name): \(profile.summary)")
        }
    }

    /// 16-bit PCM stereo. Written by hand rather than through `AVAudioFile`
    /// so the offline path needs no audio session, no engine and no device —
    /// it is arithmetic to a file, and runs anywhere the tests do.
    private static func wav(_ buffer: Soundtrack.Buffer) -> Data {
        let channels = 2, bitsPerSample = 16
        let rate = Int(Synth.sampleRate)
        let bytesPerFrame = channels * bitsPerSample / 8
        let payload = buffer.frames * bytesPerFrame

        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func uint32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func uint16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); uint32(36 + payload); ascii("WAVE")
        ascii("fmt "); uint32(16); uint16(1); uint16(channels)
        uint32(rate); uint32(rate * bytesPerFrame); uint16(bytesPerFrame); uint16(bitsPerSample)
        ascii("data"); uint32(payload)

        // Interleaved, and clamped before the cast: a `Float` a hair over 1
        // would wrap to a large negative `Int16`, which is a loud click rather
        // than the quiet distortion you might expect.
        var samples = [UInt8]()
        samples.reserveCapacity(payload)
        for index in 0 ..< buffer.frames {
            for value in [buffer.left[index], buffer.right[index]] {
                let clamped = max(-1, min(1, value))
                let scaled = Int16(clamped * 32_767)
                withUnsafeBytes(of: scaled.littleEndian) { samples.append(contentsOf: $0) }
            }
        }
        data.append(contentsOf: samples)
        return data
    }
}
