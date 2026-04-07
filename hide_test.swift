import AppKit
import CoreGraphics

let app = NSApplication.shared
app.setActivationPolicy(.regular)

class D: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        print("App launched, hiding cursor in 2s...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let r = CGDisplayHideCursor(CGMainDisplayID())
            print("CGDisplayHideCursor result: \(r.rawValue)  (0 = success)")
            print("Cursor should be HIDDEN now. Move mouse around for 5s...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                CGDisplayShowCursor(CGMainDisplayID())
                print("Cursor restored. Quitting.")
                NSApp.terminate(nil)
            }
        }
    }
}

let d = D()
app.delegate = d
app.run()
