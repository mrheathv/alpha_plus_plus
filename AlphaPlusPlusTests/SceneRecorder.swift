import AVFoundation
import SpriteKit
import XCTest
@testable import AlphaPlusPlus

/// **Frames, not a still.** Every judgement this project has made about how
/// the game looks has been made on one frame, and a still cannot answer the
/// questions that are left: whether traffic reads as traffic, whether the
/// detail tier pops as you cross it, whether the city breathes or throbs.
///
/// It drives `GameScene.update(_:)` itself at a fixed step rather than letting
/// SpriteKit run the loop, which is what makes it work with no window and no
/// display — the same reason `Capture Screenshot…` writes its own PNG instead
/// of calling `screencapture`, which fails over the remote session this
/// project is usually driven from.
///
/// **Two outputs from one pass, and the second is not a luxury.** The movie is
/// for a person. The filmstrip is for whoever cannot watch a movie — a
/// reviewer working through a terminal, which is most of this project's
/// history — and it is the only one of the two that can be looked at in the
/// same breath as the code.
///
/// ### What it can and cannot show
///
/// It advances everything the scene drives per frame: the camera, culling, the
/// `IsometricBuilding.Detail` swap, `PathVehicle`s (trams, ships, fire
/// engines), simulation ticks, and the weather turning.
///
/// It does **not** advance anything still running on an `SKAction` — road
/// traffic, the transit-diagram vehicles, the airport's aircraft, the feedback
/// flashes — because SpriteKit evaluates those on its own loop and there is no
/// public call to step it. That gap is the recorder's first real finding
/// rather than a limitation to work around: those are exactly the animations
/// `PathVehicle` was already moved off `SKAction` to avoid.
@MainActor
final class SceneRecorder {

    private let scene: GameScene
    private let view: SKView
    private let fps: Int

    /// Frames kept for the filmstrip. Deliberately a handful: a recording is
    /// hundreds of frames at 3200×2000, and holding them all is gigabytes.
    private var kept: [(label: String, image: NSImage)] = []

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameIndex = 0
    private(set) var pixelSize = CGSize.zero

    init(scene: GameScene, view: SKView, fps: Int = 30) {
        self.scene = scene
        self.view = view
        self.fps = fps
    }

    static func outputDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/Recordings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Recording

    /// Runs the scene for `seconds`, writing every frame.
    ///
    /// - Parameter steer: called before each frame with the frame index and
    ///   how far through the recording it is, so a shot can pan, zoom or
    ///   change the view as it goes. A recording of a motionless camera over a
    ///   city whose traffic does not advance is a recording of a still.
    /// - Parameter keepEvery: how often to hold a frame back for the
    ///   filmstrip.
    @discardableResult
    func record(seconds: Double,
                keepEvery: Int = 0,
                steer: (Int, Double, GameScene) -> Void = { _, _, _ in }) -> Int {
        let total = Int(seconds * Double(fps))
        let keep = keepEvery > 0 ? keepEvery : max(1, total / 8)
        for frame in 0 ..< total {
            let progress = total <= 1 ? 0 : Double(frame) / Double(total - 1)
            steer(frame, progress, scene)
            // Scene time, not wall clock: `update` takes the difference
            // between consecutive values, so a fixed step gives a steady
            // frame delta whatever the machine is doing.
            scene.update(TimeInterval(frame) / TimeInterval(fps))
            guard let image = capture() else { continue }
            append(image)
            if frame % keep == 0 {
                kept.append((String(format: "%.2fs", Double(frame) / Double(fps)),
                             NSImage(cgImage: image, size: pixelSize)))
            }
        }
        return total
    }

    private func capture() -> CGImage? {
        guard let texture = view.texture(from: scene,
                                         crop: CGRect(origin: .zero, size: scene.size))
        else { return nil }
        let image = texture.cgImage()
        if pixelSize == .zero {
            pixelSize = CGSize(width: image.width, height: image.height)
        }
        return image
    }

    // MARK: - The movie

    private func startWriterIfNeeded() {
        guard writer == nil, pixelSize != .zero,
              let url = try? Self.outputDirectory().appendingPathComponent(".pending.mov")
        else { return }
        try? FileManager.default.removeItem(at: url)
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        // H.264 wants even dimensions, and a capture at a Retina backing
        // scale is already even — but a scene sized in odd points would not
        // be, and the failure is a writer that silently produces nothing.
        let width = Int(pixelSize.width) & ~1
        let height = Int(pixelSize.height) & ~1
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        i.expectsMediaDataInRealTime = false
        let a = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: i,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard w.canAdd(i) else { return }
        w.add(i)
        w.startWriting()
        w.startSession(atSourceTime: .zero)
        writer = w; input = i; adaptor = a
    }

    /// Appends one frame, streaming rather than buffering.
    ///
    /// Buffering is not an option worth debating: a few seconds at 3200×2000
    /// is several gigabytes of `CGImage`, so frames go to the encoder as they
    /// are taken and only the filmstrip's handful are held.
    private func append(_ image: CGImage) {
        startWriterIfNeeded()
        guard let adaptor, let input, let pool = adaptor.pixelBufferPool else { return }
        // The encoder consumes on its own schedule; without this the appends
        // outrun it and start returning false.
        while !input.isReadyForMoreMediaData { usleep(500) }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return }
        context.draw(image, in: CGRect(x: 0, y: 0,
                                       width: CVPixelBufferGetWidth(buffer),
                                       height: CVPixelBufferGetHeight(buffer)))
        adaptor.append(buffer, withPresentationTime:
                        CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps)))
        frameIndex += 1
    }

    /// Finishes the movie and moves it into place. Returns `nil` if nothing
    /// was recorded.
    @discardableResult
    func writeMovie(named name: String) -> URL? {
        guard let writer, let input, frameIndex > 0 else { return nil }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        // The encoder finishes on its own queue; this is a test, so waiting is
        // correct and the alternative is a file that does not exist yet.
        _ = done.wait(timeout: .now() + 60)
        guard writer.status == .completed,
              let directory = try? Self.outputDirectory() else {
            print("⚠️  recording failed: \(writer.error?.localizedDescription ?? "unknown")")
            return nil
        }
        let destination = directory.appendingPathComponent("\(name).mov")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: writer.outputURL, to: destination)
        let seconds = Double(frameIndex) / Double(fps)
        print(String(format: "🎥 %@.mov — %d frames, %.1fs, %.0f×%.0f",
                     name, frameIndex, seconds, pixelSize.width, pixelSize.height))
        return destination
    }

    /// The same recording as a column of stills, for a reviewer who cannot
    /// play a movie.
    @discardableResult
    func writeFilmstrip(named name: String, columns: Int = 4) -> URL? {
        guard !kept.isEmpty, let directory = try? Self.outputDirectory() else { return nil }
        let cell = kept[0].image.size
        let scale = min(1, 520 / cell.width)
        let w = cell.width * scale, h = cell.height * scale
        let gap: CGFloat = 10, caption: CGFloat = 20
        let rows = Int(ceil(Double(kept.count) / Double(columns)))
        let sheet = NSImage(size: CGSize(width: CGFloat(columns) * (w + gap) + gap,
                                         height: CGFloat(rows) * (h + caption + gap) + gap))
        sheet.lockFocus()
        NSColor(white: 0.04, alpha: 1).setFill()
        NSRect(origin: .zero, size: sheet.size).fill()
        for (index, frame) in kept.enumerated() {
            let column = index % columns, row = index / columns
            let x = gap + CGFloat(column) * (w + gap)
            let y = sheet.size.height - CGFloat(row + 1) * (h + caption + gap)
            frame.image.draw(in: NSRect(x: x, y: y + caption, width: w, height: h))
            (frame.label as NSString).draw(
                at: NSPoint(x: x, y: y + 3),
                withAttributes: [.foregroundColor: NSColor(white: 0.65, alpha: 1),
                                 .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)])
        }
        sheet.unlockFocus()
        guard let tiff = sheet.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let destination = directory.appendingPathComponent("\(name)-filmstrip.png")
        try? png.write(to: destination)
        print("🎞  \(name)-filmstrip.png — \(kept.count) frames")
        return destination
    }
}
