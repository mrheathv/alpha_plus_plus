import MetalKit
import SwiftUI

/// **The map, live** (M8): the Metal renderer drawing the city, the view
/// that takes the input, and the frame loop that runs the city's clock.
///
/// Until M8 this sat underneath a transparent SpriteKit scene that kept the
/// input and the camera and ran the clock. Now it owns all three: events go
/// to `MapInteraction` through `CityMTKView`, the camera is
/// `MapInteraction.camera`, and every frame advances `CityClock`.
struct MetalMapView: NSViewRepresentable {
    let controller: GameController
    let interaction: MapInteraction
    let clock: CityClock
    /// Called with a PNG when the player asks for a screenshot.
    var onScreenshot: (Data) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, interaction: interaction, clock: clock)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = CityMTKView(frame: .zero, device: context.coordinator.renderer?.device)
        view.colorPixelFormat = .bgra8Unorm
        // The composite writes straight into the drawable from a compute
        // kernel, which a framebuffer-only drawable does not allow.
        view.framebufferOnly = false
        view.delegate = context.coordinator
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        // As fast as the display goes — 120 on a ProMotion screen.
        view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        view.input = interaction
        let controller = controller
        view.map = { [weak controller] in controller?.map }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.onScreenshot = onScreenshot
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let controller: GameController
        let interaction: MapInteraction
        let clock: CityClock
        /// The live view rebuilds changed chunks off the main thread, so a
        /// day that grows half a city does not stop the frame it lands on.
        let renderer: MetalCityRenderer? = {
            let renderer = MetalCityRenderer()
            renderer?.rebuildsInBackground = true
            return renderer
        }()
        private let started = CACurrentMediaTime()
        private var motionClock = MotionClock()
        private var lastFrame: Double?
        var onScreenshot: (Data) -> Void = { _ in }
        /// The last screenshot request answered, so each is answered once.
        private var screenshotsTaken: Int?
        /// The city generation the camera was last centred for: a load or a
        /// new city puts the camera back over the middle of the map.
        private var centredFor: Int?
        private var advancesTaken: Int?

        init(controller: GameController, interaction: MapInteraction, clock: CityClock) {
            self.controller = controller
            self.interaction = interaction
            self.clock = clock
            super.init()
            clock.runsDaysInBackground = true
            // A hazard struck: flash the building it struck, in the colour of
            // the service whose absence let it through.
            clock.onDay = { [weak self] _ in
                guard let self, let renderer = self.renderer else { return }
                let map = self.controller.map
                for strike in self.controller.lastHazardStrikes where map.contains(strike.position) {
                    let tile = map[strike.position]
                    renderer.flash(.init(origin: tile.buildingOrigin, size: tile.zone.footprintSize,
                                         kind: .hazard(strike.coveringService)))
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer, view.drawableSize.width > 0, view.bounds.width > 0 else { return }
            let now = CACurrentMediaTime()
            // Clamped like the clock, so a stall does not send the camera
            // flying.
            let elapsed = min(max(0, now - (lastFrame ?? now)), 0.1)
            lastFrame = now
            motionClock.tick(at: now, running: controller.isRunning)
            clock.advance(to: now)

            if centredFor != controller.cityGeneration {
                centredFor = controller.cityGeneration
                interaction.camera.centre(on: controller.map)
            }
            if advancesTaken == nil { advancesTaken = controller.manualAdvanceRequests }
            if controller.manualAdvanceRequests != advancesTaken {
                advancesTaken = controller.manualAdvanceRequests
                clock.runSimulationTick()
            }
            // Before the pause matters: looking around a stopped city is most
            // of what pausing is for.
            interaction.camera.applyKeyboardPan(interaction.keyboardPan, elapsed: elapsed, in: controller.map)

            renderer.showsTraffic = controller.overlayMode.showsRoadNetwork
            renderer.overlayMode = controller.overlayMode
            renderer.routeDraft = controller.routeDraft
            renderer.cursor = interaction.cursor
            for flash in interaction.takeFlashes() { renderer.flash(flash) }
            renderer.update(controller.map, revision: controller.mapRevision)
            // World points per pixel: the camera's scale is per view point,
            // and a Retina drawable has two pixels to each.
            let backing = view.drawableSize.width / view.bounds.width
            let camera = MetalCityRenderer.Camera(centre: interaction.camera.centre,
                                                  scale: interaction.camera.scale / backing,
                                                  size: view.drawableSize)
            let weather = VisualStyle.current.wetReflection > 0
            let day = controller.map.elapsedDays
            let wetness: Float = weather ? Float(Weather.wetness(onDay: day)) : 0
            let rainfall: Float = weather ? Float(Weather.rainfall(onDay: day)) : 0
            renderer.draw(in: view, camera: camera, wetness: wetness, time: Float(now - started),
                          motionClock: motionClock.seconds, rainfall: rainfall)

            // **A screenshot is the Metal frame, rendered again offscreen**, at
            // the drawable's own size, which on any Mac worth screenshotting
            // on is Retina. The cursor is left out: nobody wants it in one.
            if screenshotsTaken == nil { screenshotsTaken = controller.screenshotRequests }
            if controller.screenshotRequests != screenshotsTaken {
                screenshotsTaken = controller.screenshotRequests
                renderer.cursor = nil
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
