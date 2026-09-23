import MetalKit
import SwiftUI

/// The Metal renderer, live, underneath the SpriteKit view.
///
/// It takes no input — `GameSKView` sits on top and keeps every click, drag,
/// scroll and pinch, exactly as before — and reads the camera from the scene
/// every frame, so the two can never disagree about where the player is
/// looking. That is what lets the migration move one piece at a time: input
/// and the camera come across last, once there is nothing left on top.
struct MetalMapView: NSViewRepresentable {
    let controller: GameController
    let scene: GameScene
    /// Called with a PNG when the player asks for a screenshot.
    var onScreenshot: (Data) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, scene: scene) }

    func makeNSView(context: Context) -> MTKView {
        let view = PassThroughMTKView(frame: .zero, device: context.coordinator.renderer?.device)
        view.colorPixelFormat = .bgra8Unorm
        // The composite writes straight into the drawable from a compute
        // kernel, which a framebuffer-only drawable does not allow.
        view.framebufferOnly = false
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        // As fast as the display goes — 120 on a ProMotion screen.
        view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.onScreenshot = onScreenshot
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let controller: GameController
        let scene: GameScene
        /// The live view rebuilds changed chunks off the main thread, so a
        /// day that grows half a city does not stop the frame it lands on.
        let renderer: MetalCityRenderer? = {
            let renderer = MetalCityRenderer()
            renderer?.rebuildsInBackground = true
            return renderer
        }()
        private let started = CACurrentMediaTime()
        private var motionClock = MotionClock()
        var onScreenshot: (Data) -> Void = { _ in }
        /// The last screenshot request answered, so each is answered once.
        private var screenshotsTaken: Int?

        init(controller: GameController, scene: GameScene) {
            self.controller = controller
            self.scene = scene
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer, view.drawableSize.width > 0, view.bounds.width > 0 else { return }
            let now = CACurrentMediaTime()
            motionClock.tick(at: now, running: controller.isRunning)

            renderer.showsTraffic = controller.overlayMode.showsRoadNetwork
            renderer.overlayMode = controller.overlayMode
            renderer.update(controller.map, revision: controller.mapRevision)
            // Scene points per pixel: the camera's scale is per *view* point,
            // and a Retina drawable has two pixels to each.
            let backing = view.drawableSize.width / view.bounds.width
            let camera = MetalCityRenderer.Camera(centre: scene.cameraCentre,
                                                  scale: scene.cameraScale / backing,
                                                  size: view.drawableSize)
            let weather = VisualStyle.current.wetReflection > 0
            let day = controller.map.elapsedDays
            let wetness: Float = weather ? Float(Weather.wetness(onDay: day)) : 0
            let rainfall: Float = weather ? Float(Weather.rainfall(onDay: day)) : 0
            renderer.draw(in: view, camera: camera, wetness: wetness, time: Float(now - started),
                          motionClock: motionClock.seconds, rainfall: rainfall)

            // **A screenshot is the Metal frame, rendered again offscreen**:
            // the SpriteKit layer above is transparent in Metal mode, so its
            // capture was an empty picture. At the drawable's own size, which
            // on any Mac worth screenshotting on is Retina.
            if screenshotsTaken == nil { screenshotsTaken = controller.screenshotRequests }
            if controller.screenshotRequests != screenshotsTaken {
                screenshotsTaken = controller.screenshotRequests
                if let frame = renderer.render(controller.map, camera: camera, wetness: wetness,
                                               time: Float(now - started), motionClock: motionClock.seconds,
                                               rainfall: rainfall),
                   let png = NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]) {
                    // The save panel is modal, so it runs after this frame.
                    let handler = onScreenshot
                    DispatchQueue.main.async { handler(png) }
                }
            }
        }
    }
}

/// **Seconds the city has been running**, which is what everything that moves
/// is a function of in the Metal renderer.
///
/// It only advances while the simulation does, so pausing freezes traffic,
/// trains, flames, smoke and rain with nothing to remember to stop — the rule
/// SpriteKit reached the hard way, after its cars kept driving around a paused
/// map. The water, which is not part of the simulation, keeps the wall clock
/// and keeps moving.
struct MotionClock {
    private(set) var seconds: Double = 0
    private var last: Double?

    /// Clamped like `GameScene.update`, so a stall or a drag between displays
    /// does not send every car across the map at once.
    mutating func tick(at now: Double, running: Bool) {
        let delta = min(max(0, now - (last ?? now)), 0.1)
        last = now
        if running { seconds += delta }
    }
}

/// An `MTKView` that lets every event fall through to whatever is above or
/// below it — it is a picture, not a control.
final class PassThroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
