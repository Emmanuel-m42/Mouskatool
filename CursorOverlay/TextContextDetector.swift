import AppKit
import ApplicationServices

enum CursorContext: String {
    case normal = "normal-select-teal"
    case text   = "txt-selection-teal"
    case link   = "link-select"
    // Extend with resize/move/etc. later
}

// Polls ~20 Hz on a background queue.
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
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
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

        cursorContext = classify(el)
    }

    private func classify(_ el: AXUIElement) -> CursorContext {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &ref)
        let role = ref as? String ?? ""

        // Text input / text selection
        let textRoles: Set<String> = [
            "AXTextField", "AXTextArea", "AXSearchField", "AXSecureTextField"
        ]
        if textRoles.contains(role) { return .text }

        // Container/non-editable roles that expose kAXSelectedTextRangeAttribute
        // even though they aren't text cursors (e.g. Chrome's AXWebArea).
        let containerRoles: Set<String> = [
            "AXWebArea", "AXScrollArea", "AXGroup", "AXApplication",
            "AXWindow", "AXSplitGroup", "AXTabGroup", "AXList", "AXOutline"
        ]

        // Has a selected-text range AND a writable value → editable field in web/native content.
        // Requiring kAXValueAttribute filters out read-only containers like AXWebArea.
        if !containerRoles.contains(role) {
            var rangeRef: CFTypeRef?
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
               AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success {
                return .text
            }
        }

        // Link
        if role == "AXLink" { return .link }

        // Check parent for link role (e.g. text inside a link element)
        var parentRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
           let parent = parentRef {
            var parentRoleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent as! AXUIElement, kAXRoleAttribute as CFString, &parentRoleRef)
            if (parentRoleRef as? String) == "AXLink" { return .link }
        }

        return .normal
    }
}
