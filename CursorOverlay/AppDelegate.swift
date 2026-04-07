import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var renderer:    MetalCursorRenderer?
    private var statusItem:  NSStatusItem!
    private var debugTimer:  Timer?
    private var hotkeyMonitor: Any?

    let overlayState = OverlayState()
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibility()
        buildMenuBar()
        installHotkey()

        settingsController = SettingsWindowController(state: overlayState)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let r = MetalCursorRenderer()
            self.renderer = r
            self.overlayState.renderer = r
            r.start()
        }

        debugTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        renderer?.stop()
        if let m = hotkeyMonitor { NSEvent.removeMonitor(m) }
        debugTimer?.invalidate()
    }

    // MARK: - Accessibility

    private func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Menu bar

    private func buildMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title   = "⬡"
        statusItem.button?.toolTip = "Cursor Overlay"
        statusItem.button?.action  = #selector(statusBarClicked)
        statusItem.button?.target  = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusBarClicked() {
        settingsController?.toggle(relativeTo: statusItem.button)
    }

    // MARK: - Hotkey  (⌘⇧. — emergency kill switch)

    private func installHotkey() {
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isComboShift = event.modifierFlags
                .intersection([.command, .shift, .option, .control]) == [.command, .shift]
            guard isComboShift, event.keyCode == 47 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.overlayState.toggle()
            }
        }
    }

    // MARK: - State refresh

    private func refreshState() {
        guard let r = renderer else { return }
        overlayState.isEnabled   = r.isEnabled
        overlayState.contextName = r.textDetector.cursorContext.rawValue
        overlayState.fps         = Int(r.reportedFPS)
        overlayState.axTrusted   = AXIsProcessTrusted()
    }
}
