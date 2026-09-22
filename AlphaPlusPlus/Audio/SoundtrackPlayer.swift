import AVFoundation
import Foundation

/// **The thing that actually plays it.**
///
/// Everything else in `Audio/` is arithmetic: `Synth` makes samples,
/// `Soundtrack` makes a mix, `AudioProfile` shapes it for the speakers, and
/// `MusicDirector` says which piece the city has earned. None of it makes a
/// sound. This is the one file that talks to the device, and it is kept as
/// thin as that job allows — for the same reason `Simulation/` may import
/// only Foundation, the interesting decisions stay where they can be tested
/// without one.
///
/// **Pre-rendered buffers rather than a live render callback**, which is the
/// decision the rest of the design hangs off. A callback synthesising on the
/// audio thread cannot allocate, cannot lock and must never miss a deadline,
/// and this synth runs a resonant filter per voice per sample. Rendering a
/// track once into an `AVAudioPCMBuffer` and handing it to an
/// `AVAudioPlayerNode` moves all of that off the real-time thread, and buys
/// looping and crossfading for free. What it costs is latency the first time
/// a track is wanted, which is what the cache below is about.
@MainActor
final class SoundtrackPlayer {

    // MARK: - Rendering costs seconds, so it cannot happen on demand

    /// **Rendering a track is slow enough to be a hitch, so nothing waits for
    /// it.** A track is seconds of arithmetic per second of music; doing that
    /// when a cue changes would stall whatever asked. Every render happens on
    /// a background queue and the result is cached, so a cue change either
    /// finds its track ready or asks for it and stays on the current one
    /// until it is — the same shape `IsoTextureCache` uses for a building,
    /// one medium over.
    ///
    /// The raw mix is what is cached, *not* the profiled one: plugging in
    /// headphones changes the profile and must not cost a re-render of
    /// everything.
    private var mixes: [String: Soundtrack.Buffer] = [:]
    private var rendering: Set<String> = []
    private let renderQueue = DispatchQueue(label: "alphaplusplus.music.render", qos: .utility)

    // MARK: - The graph

    private let engine = AVAudioEngine()
    /// Two of everything, because a crossfade needs the outgoing track still
    /// playing while the incoming one starts. They swap roles each change
    /// rather than one being "the" player.
    private var decks: [Deck]
    private var front = 0

    private struct Deck {
        let node = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        var cue: MusicDirector.Cue?
    }

    /// Seconds a track change takes. Long enough that two pieces in different
    /// keys do not collide as a chord, short enough not to feel like a
    /// mistake.
    static let crossfade: TimeInterval = 2.5

    private var fade: TimeInterval = 0
    private var isFading = false

    // MARK: - What the player exposes

    /// 0 to 1. Applied to the whole graph, so it is independent of the
    /// per-track trims the score carries.
    var volume: Double = 0.6 {
        didSet { applyVolume() }
    }

    var isMuted = false {
        didSet { applyVolume() }
    }

    private(set) var profile: AudioProfile
    private(set) var cue: MusicDirector.Cue?

    /// Whether the engine came up. A Mac with no output device at all is a
    /// real state, and the game has to keep running in silence rather than
    /// failing to launch.
    private(set) var isAvailable = false

    // MARK: - Setting up

    init(profile: AudioProfile = .detected()) {
        self.profile = profile
        decks = [Deck(), Deck()]

        let format = AVAudioFormat(standardFormatWithSampleRate: Synth.sampleRate, channels: 2)!
        for deck in decks {
            engine.attach(deck.node)
            engine.attach(deck.mixer)
            engine.connect(deck.node, to: deck.mixer, format: format)
            engine.connect(deck.mixer, to: engine.mainMixerNode, format: format)
            deck.mixer.outputVolume = 0
        }
        applyVolume()
    }

    /// Start the engine. Separate from `init` because failing to open a
    /// device is a condition the caller should see rather than a crash, and
    /// because the tests drive the graph in manual-rendering mode instead.
    func start() {
        guard !isAvailable else { return }
        do {
            try engine.start()
            isAvailable = true
        } catch {
            // Silence is a survivable outcome; a game that will not launch
            // because a soundtrack could not open an output is not.
            isAvailable = false
        }
    }

    func stop() {
        for deck in decks { deck.node.stop() }
        engine.stop()
        isAvailable = false
    }

    // MARK: - Playing

    /// Put a cue on, crossfading from whatever is playing.
    ///
    /// Returns without doing anything if the track is not rendered yet — the
    /// render is started instead and the caller will ask again. That is why
    /// this takes a cue rather than a buffer: "not ready" has to be a state
    /// the player handles, not one the caller has to know about.
    func play(_ wanted: MusicDirector.Cue) {
        guard wanted != cue else { return }
        guard let buffer = buffer(for: wanted.track) else {
            requestRender(of: wanted.track)
            return
        }

        let incoming = 1 - front
        decks[incoming].node.stop()
        schedule(buffer, track: wanted.track, on: decks[incoming].node)
        decks[incoming].cue = wanted
        decks[incoming].mixer.outputVolume = 0
        decks[incoming].node.play()

        front = incoming
        cue = wanted
        fade = 0
        isFading = true
    }

    /// Advance the crossfade.
    ///
    /// **Driven by the caller rather than a timer**, for the reason
    /// `MusicDirector.update` takes an elapsed time: it makes the fade
    /// testable without waiting in real time, and the game already has a
    /// frame loop to hang it on. A timer here would also keep firing while
    /// the app is idle, which is work for nothing.
    func update(elapsed: TimeInterval) {
        guard isFading else { return }
        fade = min(Self.crossfade, fade + elapsed)
        let through = Self.crossfade > 0 ? fade / Self.crossfade : 1

        let (rising, falling) = Self.crossfadeGains(through: through)
        for (index, deck) in decks.enumerated() {
            deck.mixer.outputVolume = Float(masterVolume * (index == front ? rising : falling))
        }

        if fade >= Self.crossfade {
            isFading = false
            for (index, deck) in decks.enumerated() where index != front {
                deck.node.stop()
                decks[index].cue = nil
            }
        }
    }

    /// **Equal power, not linear.** Two uncorrelated tracks crossfaded on a
    /// straight line dip by 3 dB in the middle, which is audible as a hole —
    /// the fade reads as a fault rather than a transition. Sine and cosine
    /// keep the sum of the *powers* constant across it, which is the right
    /// conservation for two signals that are not related to each other.
    ///
    /// Extracted rather than written inline for the reason `LotStatus` is a
    /// value: the decision becomes something a test can ask about, instead of
    /// something that can only be run and listened to.
    static func crossfadeGains(through: Double) -> (rising: Double, falling: Double) {
        let clamped = max(0, min(1, through))
        return (sin(clamped * .pi / 2), cos(clamped * .pi / 2))
    }

    // MARK: - Looping

    /// Schedule a track so it plays its introduction once and then loops.
    ///
    /// **`Track.loopsFromBar` is why this is not one call.** A track whose
    /// pad is alone for four bars and whose drums arrive at eight has a
    /// shape, and a shape is something you hear once — looping the whole
    /// thing would replay the introduction every time round, which is the
    /// surest way to make an arrangement sound like a loop.
    private func schedule(_ buffer: AVAudioPCMBuffer, track: Track, on node: AVAudioPlayerNode) {
        let loopStart = loopStartFrame(of: track)
        guard loopStart > 0, loopStart < buffer.frameLength,
              let tail = slice(buffer, from: loopStart) else {
            node.scheduleBuffer(buffer, at: nil, options: .loops)
            return
        }
        node.scheduleBuffer(buffer, at: nil, options: [])
        node.scheduleBuffer(tail, at: nil, options: .loops)
    }

    func loopStartFrame(of track: Track) -> AVAudioFramePosition {
        let framesPerBar = Double(track.beatsPerBar) * track.secondsPerBeat * Synth.sampleRate
        return AVAudioFramePosition(Double(track.loopsFromBar) * framesPerBar)
    }

    private func slice(_ buffer: AVAudioPCMBuffer, from start: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let count = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - start)
        guard count > 0,
              let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let source = buffer.floatChannelData, let destination = tail.floatChannelData
        else { return nil }
        for channel in 0 ..< Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + Int(start), count: Int(count))
        }
        tail.frameLength = count
        return tail
    }

    // MARK: - The speakers changed

    /// Re-shape for a different set of speakers.
    ///
    /// The raw mixes are kept, so this costs one pass over a buffer rather
    /// than a re-render. The current track restarts through its crossfade,
    /// which is honest in both cases this happens: plugging in headphones
    /// already interrupts the audio device, and changing the setting by hand
    /// is a thing the player just did and expects to hear.
    func setProfile(_ new: AudioProfile) {
        guard new != profile else { return }
        profile = new
        guard let playing = cue else { return }
        cue = nil
        play(playing)
    }

    // MARK: - Rendering, off the main thread

    private func buffer(for track: Track) -> AVAudioPCMBuffer? {
        guard let mix = mixes[track.name] else { return nil }
        return Self.pcmBuffer(profile.apply(to: mix))
    }

    private func requestRender(of track: Track) {
        guard mixes[track.name] == nil, !rendering.contains(track.name) else { return }
        rendering.insert(track.name)
        renderQueue.async {
            let mix = Soundtrack.render(track)
            Task { @MainActor in
                self.mixes[track.name] = mix
                self.rendering.remove(track.name)
            }
        }
    }

    /// Render everything, in the background, in the order a session will
    /// want it. Called once at launch so a cue change lands on a cache hit.
    func warmUp(_ cues: [MusicDirector.Cue] = MusicDirector.Cue.allCases) {
        for cue in cues { requestRender(of: cue.track) }
    }

    func isReady(_ cue: MusicDirector.Cue) -> Bool { mixes[cue.track.name] != nil }

    static func pcmBuffer(_ mix: Soundtrack.Buffer) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: Synth.sampleRate, channels: 2)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(mix.frames)),
              let channels = buffer.floatChannelData
        else { return nil }
        mix.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: mix.frames) }
        mix.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: mix.frames) }
        buffer.frameLength = AVAudioFrameCount(mix.frames)
        return buffer
    }

    // MARK: - Level

    private var masterVolume: Double { isMuted ? 0 : max(0, min(1, volume)) }

    private func applyVolume() {
        // Only the deck that is in front carries the level; the other is
        // either silent or mid-fade, and `update` owns it then.
        guard !isFading else { return }
        for (index, deck) in decks.enumerated() {
            deck.mixer.outputVolume = index == front && cue != nil ? Float(masterVolume) : 0
        }
    }

    // MARK: - For the tests

    /// Run the graph with no audio device, the way `SKView.texture(from:)`
    /// renders a scene with no window. This is what lets the crossfade and
    /// the loop point be asserted on rather than listened for.
    func enableOfflineRendering(maximumFrameCount: AVAudioFrameCount = 4_096) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: Synth.sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: maximumFrameCount)
        try engine.start()
        isAvailable = true
    }

    func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                      frameCapacity: frames)!
        _ = try engine.renderOffline(frames, to: buffer)
        return buffer
    }

    /// Put a rendered mix straight into the cache, so a test does not pay for
    /// a real render to check the plumbing around one.
    func preload(_ cue: MusicDirector.Cue, with mix: Soundtrack.Buffer) {
        mixes[cue.track.name] = mix
    }
}
