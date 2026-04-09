import Metal
import MetalKit
import QuartzCore
import CoreVideo
import AppKit

struct CursorUniforms {
    var normPos:   SIMD2<Float>
    var normSize:  SIMD2<Float>
    var fadeAlpha: Float = 1
}

struct RingUniforms {
    var normCenter:    SIMD2<Float>
    var normRadius:    Float         // in screen-height-normalized units
    var normThickness: Float
    var alpha:         Float
    var aspectRatio:   Float         // screenWidth / screenHeight
    var colorR:        Float
    var colorG:        Float
    var colorB:        Float
    var _pad:          Float = 0
}

private struct CursorEntry {
    let texture: MTLTexture
    let hotspot: CGPoint   // logical points (1pt = image pixel, image rendered at 1px/pt)
    let size:    CGFloat   // display size in logical points
}

final class MetalCursorRenderer {
    // MARK: - Metal
    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue
    private let pipeline:      MTLRenderPipelineState
    private let uniformBuffer: MTLBuffer

    // Cursor atlas: keyed by CursorContext.rawValue (e.g. "normal-select-teal")
    private var cursors:     [String: CursorEntry] = [:]
    // Render at exactly imageWidth/backingScale logical points → 1:1 pixel mapping on Retina.
    // 48px ÷ 2x = 24pt → 48 physical pixels = no scaling artifacts.
    private static let displayPt: CGFloat = 24

    // MARK: - Window
    let window: OverlayWindow
    private var metalLayer: CAMetalLayer { window.metalView.metalLayer }

    // MARK: - Display link
    private var displayLink: CVDisplayLink?

    // MARK: - State
    private(set) var isEnabled:         Bool         = true
    var             highPerformanceMode: Bool         = false
    private      var lastContext:       CursorContext = .normal
    private      var cursorHidden:      Bool         = false
    private      var hideCount:         Int          = 0
    private      var lastRenderedPos:   CGPoint      = CGPoint(x: -9999, y: -9999)
    private      let renderLock                      = NSLock()

    // Dissolve/ring-ripple animation — driven by CGCursorIsVisible each tick.
    private var explodeT:          Float  = 0.0
    private var lastTickTime:      Double = 0.0
    var ringColor:                 SIMD3<Float> = SIMD3(0.15, 0.85, 0.95)

    // MARK: - Ring pipeline
    private var ringPipeline:      MTLRenderPipelineState!
    private var ringUniformBuffer: MTLBuffer!

    // MARK: - Event tap
    private var eventTap:      CFMachPort?
    private var tapLoopSource: CFRunLoopSource?

    // MARK: - Text detection
    let textDetector = TextContextDetector()

    // MARK: - FPS / misc counters
    private var frameCount:    Int            = 0
    private var lastFPSTime:   CFAbsoluteTime = 0
    private(set) var reportedFPS: Double      = 0
    private var tapRetryCount: Int            = 0   // throttles event-tap retry

    // MARK: - Init

    init() {
        // Allow this process to hide/set the cursor while in the background.
        let cid = _CGSDefaultConnection()
        CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)

        guard let dev = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
        device       = dev
        commandQueue = device.makeCommandQueue()!

        let screen = NSScreen.main!
        window = OverlayWindow(screen: screen)

        let layer = window.metalView.metalLayer
        layer.device        = device
        layer.contentsScale = screen.backingScaleFactor

        pipeline      = Self.makePipeline(device: device, pixelFormat: layer.pixelFormat)
        uniformBuffer = device.makeBuffer(length: MemoryLayout<CursorUniforms>.size,
                                           options: .storageModeShared)!

        ringPipeline      = Self.makeRingPipeline(device: device, pixelFormat: layer.pixelFormat)
        ringUniformBuffer = device.makeBuffer(length: MemoryLayout<RingUniforms>.size,
                                               options: .storageModeShared)!

        cursors = Self.loadCursors(device: device)
    }

    // MARK: - Lifecycle

    func start() {
        textDetector.start()
        window.makeKeyAndOrderFront(nil)
        lastFPSTime = CFAbsoluteTimeGetCurrent()
        startDisplayLink()
        installEventTap()
        installWorkspaceObservers()
    }

    func stop() {
        stopDisplayLink()
        removeEventTap()
        textDetector.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        restoreCursor()
    }

    func enable()  { isEnabled = true;  installEventTap() }
    func disable() { isEnabled = false; removeEventTap(); restoreCursor(); clearLayer() }

    // MARK: - Render tick  (called from CVDisplayLink background thread)

    func tick() {
        guard isEnabled else { return }

        hideCursorNow()

        // Retry event tap every ~600 frames (~5s at 120fps) until it installs.
        if eventTap == nil {
            tapRetryCount += 1
            if tapRetryCount >= 600 {
                tapRetryCount = 0
                DispatchQueue.main.async { [weak self] in self?.installEventTap() }
            }
        }

        // Drive dissolve/reassemble animation.
        let now = CACurrentMediaTime()
        let dt  = Float(lastTickTime > 0 ? min(now - lastTickTime, 0.05) : 0)
        lastTickTime = now
        let cursorVisible = _CGCursorIsVisible() != 0
        if cursorVisible {
            explodeT = min(1.0, explodeT + dt * 8.0)
        } else {
            explodeT = max(0.0, explodeT - dt * 12.0)
        }

        guard let cgPos = CGEvent(source: nil)?.location else { return }

        // Render if position changed OR animation is in progress.
        guard cgPos != lastRenderedPos || explodeT > 0 else { return }

        renderFrame(at: cgPos)
        trackFPS()
    }

    // Called from the event tap in high performance mode.
    // Renders immediately on mouse move instead of waiting for the next CVDisplayLink tick.
    func renderFromEventTap() {
        guard isEnabled, highPerformanceMode else { return }
        guard let cgPos = CGEvent(source: nil)?.location else { return }
        guard cgPos != lastRenderedPos else { return }
        // tryLock: if CVDisplayLink is already rendering, skip — don't block the event pipeline.
        guard renderLock.try() else { return }
        defer { renderLock.unlock() }
        renderFrame(at: cgPos)
    }

    private func renderFrame(at cgPos: CGPoint) {
        let context = textDetector.cursorContext
        lastContext = context

        guard let entry = cursors[context.rawValue] ?? cursors[CursorContext.normal.rawValue] else { return }

        // Acquire render lock when called from CVDisplayLink (not already held).
        // Event tap path already holds it via tryLock.
        let needsLock = !highPerformanceMode
        if needsLock { renderLock.lock() }
        defer { if needsLock { renderLock.unlock() } }

        let screen = NSScreen.main!
        let sw = screen.frame.width
        let sh = screen.frame.height

        let tlX = cgPos.x - entry.hotspot.x
        let tlY = cgPos.y - entry.hotspot.y

        var u = CursorUniforms(
            normPos:   SIMD2(Float(tlX / sw),        Float(tlY / sh)),
            normSize:  SIMD2(Float(entry.size / sw), Float(entry.size / sh)),
            fadeAlpha: 1.0 - explodeT
        )
        memcpy(uniformBuffer.contents(), &u, MemoryLayout<CursorUniforms>.size)

        // Ring uniforms — radius in screen-height-normalized units.
        let axScale   = Float(UserDefaults(suiteName: "com.apple.universalaccess")?
                            .double(forKey: "mouseDriverCursorSize") ?? 1.0)
        let maxRadius     = Float(entry.size) / Float(sh) * 1.5 * axScale
        let normThickness = maxRadius * 0.08
        var ru = RingUniforms(
            normCenter:    SIMD2(Float(cgPos.x / sw), Float(cgPos.y / sh)),
            normRadius:    explodeT * maxRadius,
            normThickness: normThickness,
            alpha:         smoothstep(0.0, 0.2, explodeT),
            aspectRatio:   Float(sw / sh),
            colorR:        ringColor.x,
            colorG:        ringColor.y,
            colorB:        ringColor.z
        )
        memcpy(ringUniformBuffer.contents(), &ru, MemoryLayout<RingUniforms>.size)

        lastRenderedPos = cgPos

        render(texture: entry.texture)
    }

    // MARK: - Metal draw

    private func render(texture: MTLTexture) {
        guard let drawable = metalLayer.nextDrawable() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture     = drawable.texture
        rpd.colorAttachments[0].loadAction  = .clear
        rpd.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store

        guard let buf = commandQueue.makeCommandBuffer(),
              let enc = buf.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // Pass 1: cursor (faded)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Pass 2: ring ripple (only while animation is active)
        if explodeT > 0 {
            enc.setRenderPipelineState(ringPipeline)
            enc.setVertexBuffer(ringUniformBuffer, offset: 0, index: 0)
            enc.setFragmentBuffer(ringUniformBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        enc.endEncoding()

        buf.present(drawable)
        buf.commit()
    }

    private func clearLayer() {
        guard let drawable = metalLayer.nextDrawable() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture     = drawable.texture
        rpd.colorAttachments[0].loadAction  = .clear
        rpd.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let buf = commandQueue.makeCommandBuffer(),
              let enc = buf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.endEncoding()
        buf.present(drawable)
        buf.commit()
    }

    // MARK: - System cursor

    func hideCursorNow() {
        guard isEnabled else { return }
        // Loop until CGCursorIsVisible confirms it's hidden — guards against the Dock
        // or macOS calling CGDisplayShowCursor and incrementing the counter past 0.
        var attempts = 0
        while _CGCursorIsVisible() != 0, attempts < 10 {
            CGDisplayHideCursor(CGMainDisplayID())
            hideCount += 1
            attempts += 1
        }
        cursorHidden = true
    }

    private func restoreCursor() {
        guard cursorHidden else { return }
        cursorHidden = false
        let n = hideCount
        hideCount = 0
        for _ in 0 ..< max(n, 1) {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    // MARK: - CGEventTap

    func installEventTap() {
        guard eventTap == nil else { return }
        let trusted = AXIsProcessTrusted()
        try? "installEventTap called, AXTrusted=\(trusted)\n".appendingToFile("/tmp/cursor_debug.txt")
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        eventTap = CGEvent.tapCreate(
            tap:              .cgSessionEventTap,
            place:            .tailAppendEventTap,
            options:          .defaultTap,
            eventsOfInterest: mask,
            callback:         cursorTapCallback,
            userInfo:         Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap = eventTap else {
            try? "CGEventTap creation FAILED\n".appendingToFile("/tmp/cursor_debug.txt")
            return
        }
        try? "CGEventTap created OK\n".appendingToFile("/tmp/cursor_debug.txt")
        tapLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = tapLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        }
        eventTap = nil
        tapLoopSource = nil
    }

    // MARK: - Workspace observers

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        // Fires when returning from Mission Control or switching spaces.
        // macOS force-shows the cursor during expose; re-hide and re-raise overlay.
        nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            self.cursorHidden = false
            self.hideCursorNow()
            // Re-raise our overlay — Mission Control can disrupt window ordering.
            self.window.orderFrontRegardless()
        }

        // Fires when any app activates — reset hide state and re-hide immediately.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] n in
            guard let self, self.isEnabled else { return }
            self.cursorHidden = false
            self.hideCursorNow()
        }
    }

    // MARK: - FPS

    private func trackFPS() {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let dt  = now - lastFPSTime
        if dt >= 1.0 {
            reportedFPS = Double(frameCount) / dt
            frameCount  = 0
            lastFPSTime = now
        }
    }

    // MARK: - Cursor loading

    // Loads all cursor PNGs from the app bundle using cursors.json for hotspot metadata.
    // Falls back to a procedural arrow if the bundle has no cursor pack.
    private static func loadCursors(device: MTLDevice) -> [String: CursorEntry] {
        let loader = MTKTextureLoader(device: device)
        var result: [String: CursorEntry] = [:]
        var log = "--- loadCursors ---\nresourceURL: \(Bundle.main.resourceURL?.path ?? "nil")\n"

        guard let jsonURL  = Bundle.main.url(forResource: "cursors", withExtension: "json", subdirectory: "Resources") ?? Bundle.main.url(forResource: "cursors", withExtension: "json"),
              let jsonData = try? Data(contentsOf: jsonURL),
              let manifest = try? JSONSerialization.jsonObject(with: jsonData) as? [String: [String: Any]]
        else {
            log += "cursors.json not found or failed to parse\n"
            try? log.appendingToFile("/tmp/cursor_debug.txt")
            let t = makeProceduralArrow(device: device)
            let f = CursorEntry(texture: t, hotspot: CGPoint(x: 3, y: 2), size: 28)
            return [CursorContext.normal.rawValue: f, CursorContext.text.rawValue: f, CursorContext.link.rawValue: f]
        }

        log += "cursors.json OK, \(manifest.count) entries\n"

        for (name, meta) in manifest {
            guard let hotx = meta["hotx"] as? Int,
                  let hoty = meta["hoty"] as? Int,
                  let w    = meta["w"]    as? Int else { log += "  \(name): bad meta\n"; continue }

            guard let pngURL = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Resources") ?? Bundle.main.url(forResource: name, withExtension: "png") else {
                log += "  \(name): PNG not found\n"; continue
            }
            // Use CGImageSource to load exact pixel data — NSImage can silently rescale or
            // change the alpha mode depending on screen context.
            guard let src = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
                  let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                log += "  \(name): CGImageSource failed\n"; continue
            }
            guard let tex = try? loader.newTexture(cgImage: cg, options: [.SRGB: false]) else {
                log += "  \(name): MTKTextureLoader failed\n"; continue
            }

            // Scale hotspot proportionally from image pixels to display points.
            let scale = displayPt / CGFloat(w)
            result[name] = CursorEntry(
                texture: tex,
                hotspot: CGPoint(x: CGFloat(hotx) * scale, y: CGFloat(hoty) * scale),
                size:    displayPt
            )
            log += "  \(name): OK\n"
        }

        log += "Loaded \(result.count) cursors\n"
        try? log.appendingToFile("/tmp/cursor_debug.txt")

        // Ensure every context has a fallback
        let fallbackTex = makeProceduralArrow(device: device)
        let fallback = CursorEntry(texture: fallbackTex, hotspot: CGPoint(x: 3, y: 2), size: 28)
        for ctx in [CursorContext.normal, .text, .link] {
            if result[ctx.rawValue] == nil { result[ctx.rawValue] = fallback }
        }

        return result
    }

    // MARK: - Metal setup

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertexOut { float4 position [[position]]; float2 uv; };
        struct CursorUniforms { float2 normPos; float2 normSize; float fadeAlpha; };
        struct RingUniforms   { float2 normCenter; float normRadius; float normThickness; float alpha; float aspectRatio; float colorR; float colorG; float colorB; float pad; };

        vertex VertexOut cursor_vertex(uint vid [[vertex_id]],
                                        constant CursorUniforms& u [[buffer(0)]]) {
            const float2 corners[4] = {float2(0,0),float2(1,0),float2(0,1),float2(1,1)};
            const float2 uvs[4]     = {float2(0,0),float2(1,0),float2(0,1),float2(1,1)};
            float2 norm = u.normPos + corners[vid] * u.normSize;
            float2 ndc  = float2(norm.x * 2.0 - 1.0, 1.0 - norm.y * 2.0);
            VertexOut o; o.position = float4(ndc, 0, 1); o.uv = uvs[vid]; return o;
        }
        fragment float4 cursor_fragment(VertexOut in [[stage_in]],
                                         constant CursorUniforms& u [[buffer(0)]],
                                         texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_zero);
            float4 color = tex.sample(s, in.uv);
            color.a *= u.fadeAlpha;
            return color;
        }

        vertex VertexOut ring_vertex(uint vid [[vertex_id]],
                                      constant RingUniforms& u [[buffer(0)]]) {
            float padY = u.normRadius + u.normThickness * 3.0 + 0.002;
            float padX = padY / u.aspectRatio;
            const float2 corners[4] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
            float2 norm = u.normCenter + corners[vid] * float2(padX, padY);
            float2 ndc  = float2(norm.x * 2.0 - 1.0, 1.0 - norm.y * 2.0);
            VertexOut o; o.position = float4(ndc, 0, 1);
            o.uv = corners[vid] * 0.5 + 0.5; return o;
        }
        fragment float4 ring_fragment(VertexOut in [[stage_in]],
                                       constant RingUniforms& u [[buffer(0)]]) {
            float  padY    = u.normRadius + u.normThickness * 3.0 + 0.002;
            float2 corners = (in.uv - float2(0.5)) * 2.0;
            float2 offset  = corners * padY;
            float  dist    = length(offset);
            float outer  = u.normRadius;
            float inner  = outer - u.normThickness;
            float px     = 0.0008;
            float ring   = smoothstep(inner - px, inner + px, dist)
                         * smoothstep(outer + px, outer - px, dist);
            float glow   = smoothstep(inner, outer + u.normThickness * 1.5, dist)
                         * smoothstep(outer + u.normThickness * 3.0, outer, dist) * 0.20;
            float a = clamp(ring + glow, 0.0, 1.0) * u.alpha;
            return float4(u.colorR, u.colorG, u.colorB, a);
        }
    """

    private static func makePipeline(device: MTLDevice,
                                      pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState {
        let lib: MTLLibrary
        if let defaultLib = device.makeDefaultLibrary() {
            lib = defaultLib
        } else {
            lib = try! device.makeLibrary(source: shaderSource, options: nil)
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction   = lib.makeFunction(name: "cursor_vertex")!
        d.fragmentFunction = lib.makeFunction(name: "cursor_fragment")!
        d.colorAttachments[0].pixelFormat = pixelFormat

        // Straight (non-premultiplied) alpha blend.
        // PNG cursor pack stores straight alpha; using .one for src RGB causes dark fringing.
        let ca = d.colorAttachments[0]!
        ca.isBlendingEnabled             = true
        ca.sourceRGBBlendFactor          = .sourceAlpha
        ca.destinationRGBBlendFactor     = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor        = .one
        ca.destinationAlphaBlendFactor   = .oneMinusSourceAlpha

        return try! device.makeRenderPipelineState(descriptor: d)
    }

    private static func makeRingPipeline(device: MTLDevice,
                                          pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState {
        let lib: MTLLibrary
        if let defaultLib = device.makeDefaultLibrary() {
            lib = defaultLib
        } else {
            lib = try! device.makeLibrary(source: shaderSource, options: nil)
        }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction   = lib.makeFunction(name: "ring_vertex")!
        d.fragmentFunction = lib.makeFunction(name: "ring_fragment")!
        d.colorAttachments[0].pixelFormat = pixelFormat

        let ca = d.colorAttachments[0]!
        ca.isBlendingEnabled           = true
        ca.sourceRGBBlendFactor        = .sourceAlpha
        ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try! device.makeRenderPipelineState(descriptor: d)
    }

    private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private static func makeProceduralArrow(device: MTLDevice) -> MTLTexture {
        let pts = 32, scale = 2, px = pts * scale
        var pixels = [UInt8](repeating: 0, count: px * px * 4)

        guard let ctx = CGContext(
            data: &pixels, width: px, height: px,
            bitsPerComponent: 8, bytesPerRow: px * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { fatalError("CGContext failed") }

        ctx.translateBy(x: 0, y: CGFloat(px))
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))

        let arrow = CGMutablePath()
        arrow.move(to:    CGPoint(x: 3,  y: 2))
        arrow.addLine(to: CGPoint(x: 3,  y: 26))
        arrow.addLine(to: CGPoint(x: 20, y: 14))
        arrow.closeSubpath()

        ctx.addPath(arrow)
        ctx.setFillColor(CGColor.white)
        ctx.setStrokeColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.95))
        ctx.setLineWidth(2.5)
        ctx.drawPath(using: .fillStroke)

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: px, height: px, mipmapped: false)
        td.usage       = .shaderRead
        td.storageMode = .shared
        let tex = device.makeTexture(descriptor: td)!
        tex.replace(region: MTLRegionMake2D(0, 0, px, px),
                    mipmapLevel: 0, withBytes: pixels, bytesPerRow: px * 4)
        return tex
    }
}

// MARK: - Private CGS / CG declarations

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ targetCid: Int32, _ key: CFString, _ value: CFTypeRef)

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> Int32

// CGCursorIsVisible is deprecated in the SDK headers but the symbol still ships in macOS 14+.
// Returns non-zero when the cursor is currently visible.
@_silgen_name("CGCursorIsVisible")
private func _CGCursorIsVisible() -> Int32

// MARK: - Debug helper

private extension String {
    func appendingToFile(_ path: String) throws {
        let url = URL(fileURLWithPath: path)
        if let data = data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            } else {
                try data.write(to: url)
            }
        }
    }
}

// MARK: - CGEventTap C callback

private func cursorTapCallback(
    _ proxy:    CGEventTapProxy,
    _ type:     CGEventType,
    _ event:    CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let ptr = userInfo {
        let r = Unmanaged<MetalCursorRenderer>.fromOpaque(ptr).takeUnretainedValue()
        r.hideCursorNow()
        r.renderFromEventTap()   // no-op unless highPerformanceMode is on
    }
    return Unmanaged.passRetained(event)
}

// MARK: - CVDisplayLink C callback

private func cvCallback(
    _ dl:       CVDisplayLink,
    _ now:      UnsafePointer<CVTimeStamp>,
    _ outTime:  UnsafePointer<CVTimeStamp>,
    _ flagsIn:  CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx:      UnsafeMutableRawPointer?
) -> CVReturn {
    Unmanaged<MetalCursorRenderer>.fromOpaque(ctx!).takeUnretainedValue().tick()
    return kCVReturnSuccess
}

// MARK: - CVDisplayLink helpers

extension MetalCursorRenderer {
    func startDisplayLink() {
        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let dl else { return }
        CVDisplayLinkSetOutputCallback(dl, cvCallback,
                                       Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
        displayLink = dl
    }

    func stopDisplayLink() {
        guard let dl = displayLink else { return }
        CVDisplayLinkStop(dl)
        displayLink = nil
    }
}
