import AppKit
import QuartzCore
import Metal

// Transparent, always-on-top, click-through panel covering the full screen.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Stay above essentially everything; screen saver level (1000) is well above
        // normal app windows (0-100) and the menu bar (24).
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true   // all clicks pass through
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        contentView = MetalView(frame: screen.frame)
    }

    var metalView: MetalView { contentView as! MetalView }
}

// NSView whose backing layer is a CAMetalLayer.
final class MetalView: NSView {
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false          // transparent background
        layer.framebufferOnly = true
        layer.displaySyncEnabled = false // CVDisplayLink owns timing
        return layer
    }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never  // we drive rendering ourselves
    }

    required init?(coder: NSCoder) { fatalError() }
}
