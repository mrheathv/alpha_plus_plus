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

    func updateNSView(_ nsView: MTKView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let controller: GameController
        let scene: GameScene
        let renderer = MetalCityRenderer()
        private let started = CACurrentMediaTime()

        init(controller: GameController, scene: GameScene) {
            self.controller = controller
            self.scene = scene
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer, view.drawableSize.width > 0, view.bounds.width > 0 else { return }
            renderer.update(controller.map, revision: controller.mapRevision)
            // Scene points per pixel: the camera's scale is per *view* point,
            // and a Retina drawable has two pixels to each.
            let backing = view.drawableSize.width / view.bounds.width
            let camera = MetalCityRenderer.Camera(centre: scene.cameraCentre,
                                                  scale: scene.cameraScale / backing,
                                                  size: view.drawableSize)
            let wetness = VisualStyle.current.wetReflection > 0
                ? Float(Weather.wetness(onDay: controller.map.elapsedDays)) : 0
            renderer.draw(in: view, camera: camera, wetness: wetness,
                          time: Float(CACurrentMediaTime() - started))
        }
    }
}

/// An `MTKView` that lets every event fall through to whatever is above or
/// below it — it is a picture, not a control.
final class PassThroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
