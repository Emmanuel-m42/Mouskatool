# Mouskatool

A macOS app that replaces your system cursor with a custom cursor pack, system-wide. Built with Metal for low-latency rendering.

Uses only public macOS APIs.

---

## How it works

- Hides the real system cursor using `CGDisplayHideCursor`
- Renders a custom cursor sprite over the screen using a Metal overlay window at screen saver level
- Detects cursor context (text field, link, normal) via the Accessibility API and switches cursor images automatically
- Runs at display refresh rate via CVDisplayLink

## Requirements

- macOS 26 (Tahoe) or later
- Accessibility permission (app will prompt on first launch)

## Setup

1. Build with Xcode or `swiftc` (see below)
2. Run the app
3. Grant Accessibility permission when prompted
4. Click the menu bar icon to open the settings panel

### Build from source

```bash
swiftc \
  CursorOverlay/main.swift \
  CursorOverlay/AppDelegate.swift \
  CursorOverlay/OverlayWindow.swift \
  CursorOverlay/MetalCursorRenderer.swift \
  CursorOverlay/TextContextDetector.swift \
  CursorOverlay/SettingsView.swift \
  -framework Cocoa -framework Metal -framework MetalKit \
  -framework CoreVideo -framework ApplicationServices \
  -framework SwiftUI \
  -target arm64-apple-macosx14.0 \
  -o build/CursorOverlay.app/Contents/MacOS/CursorOverlay

codesign --sign - --force --deep build/CursorOverlay.app
open build/CursorOverlay.app
```

## Cursor pack

Comes with the Android Material Teal cursor pack, converted from `.cur` to PNG using `convert_cursors.py`. Drop your own PNGs into `Resources/` alongside a `cursors.json` hotspot file to use a different pack.

## Known issues

- Cursor briefly reappears when hovering over the Dock
- Cursor briefly reappears when entering or exiting Mission Control
- Context switching (text/link detection) only works in native apps and some web content -- does not work in all browsers

## More features coming soon
