import MetalKit
import SwiftUI

/// The globe, full screen under the glass. One finger turns it, two zoom, a
/// tap picks the nearest satellite (or, on empty sky, puts the card away).
struct GlobeView: UIViewRepresentable {
    let model: AppModel
    /// Off while the app is in the background: Metal may not draw then.
    var active: Bool

    func makeUIView(context: Context) -> GlobeMTKView {
        GlobeMTKView(model: model)
    }

    func updateUIView(_ view: GlobeMTKView, context: Context) {
        view.isPaused = !active
    }
}

final class GlobeMTKView: MTKView, UIGestureRecognizerDelegate {
    private var renderer: GlobeRenderer?
    private let model: AppModel
    private var lastPinch: CGFloat = 1

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        sampleCount = 4
        preferredFramesPerSecond = 60
        isOpaque = true
        renderer = GlobeRenderer(view: self, model: model)
        delegate = renderer
        renderer?.dark = traitCollection.userInterfaceStyle != .light
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: GlobeMTKView, _) in
            view.renderer?.dark = view.traitCollection.userInterfaceStyle != .light
        }
        isAccessibilityElement = true
        accessibilityLabel = "Globe with live satellites"
        accessibilityHint = "Drag to turn it, pinch to zoom, tap a satellite for its details."

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
        addGestureRecognizer(tap)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // A finger on the globe stops it turning by itself, as on Android.
        renderer?.touched()
    }

    @objc private func onPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        renderer?.camera.drag(dx: t.x, dy: t.y, height: max(bounds.height, 1))
        g.setTranslation(.zero, in: self)
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { lastPinch = 1 }
        renderer?.camera.pinch(ratio: g.scale / lastPinch)
        lastPinch = g.scale
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        guard let renderer else { return }
        model.tapped(norad: renderer.pick(at: g.location(in: self)))
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
