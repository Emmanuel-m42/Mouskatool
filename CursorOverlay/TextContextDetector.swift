import AppKit
import ApplicationServices

enum CursorContext: String {
    case normal = "normal-select-teal"
    case text   = "txt-selection-teal"
    case link   = "link-select"
}

// Polls ~30 Hz on a background queue.
final class TextContextDetector {
    private let lock = NSLock()
    private var _context: CursorContext = .normal
    var cursorContext: CursorContext {
        get { lock.withLock { _context } }
        set { lock.withLock { _context = newValue } }
    }

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.cursoroverlay.textdetect", qos: .userInteractive)

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))  // ~30 Hz
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        // Primary: read what cursor the active app has set at the WindowServer level.
        // This works for any app (browsers, Electron, etc.) without AX permission.
        if let ctx = contextFromSystemCursor() {
            cursorContext = ctx
            return
        }

        // Fallback: AX element inspection (requires Accessibility permission).
        guard AXIsProcessTrusted() else { return }

        let nsLoc = NSEvent.mouseLocation
        guard let screen = NSScreen.main else { return }
        let axX = Float(nsLoc.x)
        let axY = Float(screen.frame.height - nsLoc.y)

        let sys = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, axX, axY, &element) == .success,
              let el = element else {
            cursorContext = .normal
            return
        }

        cursorContext = classifyAX(el)
    }

    // MARK: - System cursor detection
    //
    // NSCursor.currentSystem returns nil when the hardware cursor is hidden —
    // macOS won't expose the cursor type if nothing is visible (safety feature).
    // So we only use it for POSITIVE identification of non-normal states.
    // If it returns pointingHand or iBeam we trust it immediately.
    // If it returns nil or the default arrow we fall through to AX.
    private func contextFromSystemCursor() -> CursorContext? {
        var ctx: CursorContext? = nil
        DispatchQueue.main.sync {
            guard let sysCursor = NSCursor.currentSystem else { return }
            if sysCursor == NSCursor.pointingHand {
                ctx = .link
            } else if sysCursor == NSCursor.iBeam ||
                      sysCursor == NSCursor.iBeamCursorForVerticalLayout {
                ctx = .text
            }
            // Arrow / anything else → return nil, let AX decide
        }
        return ctx
    }

    // MARK: - AX fallback

    private func classifyAX(_ el: AXUIElement) -> CursorContext {
        // Walk up to 5 ancestor levels checking for link and text indicators.
        var current: AXUIElement = el

        for depth in 0...5 {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            // Text inputs — only check at the element itself, not ancestors
            if depth == 0 {
                let textRoles: Set<String> = [
                    "AXTextField", "AXTextArea", "AXSearchField",
                    "AXSecureTextField", "AXComboBox"
                ]
                if textRoles.contains(role) { return .text }

                // Editable web/native fields: must have both a text range and a value
                let containerRoles: Set<String> = [
                    "AXWebArea", "AXScrollArea", "AXGroup", "AXApplication",
                    "AXWindow", "AXSplitGroup", "AXTabGroup", "AXList", "AXOutline"
                ]
                if !containerRoles.contains(role) {
                    var rangeRef: CFTypeRef?
                    var valueRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(current, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
                       AXUIElementCopyAttributeValue(current, kAXValueAttribute as CFString, &valueRef) == .success {
                        return .text
                    }
                }
            }

            // Link role at any level
            if role == "AXLink" { return .link }

            // URL attribute at any level — browsers expose this on link ancestors
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXURLAttribute as CFString, &urlRef) == .success,
               urlRef != nil {
                return .link
            }

            // Walk up to parent
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            current = (parent as! AXUIElement)
        }

        return .normal
    }
}
