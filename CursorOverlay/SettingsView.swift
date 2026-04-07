import SwiftUI
import AppKit

// MARK: - Shared state

final class OverlayState: ObservableObject {
    @Published var isEnabled:           Bool   = true
    @Published var highPerformanceMode: Bool   = false
    @Published var contextName:         String = "—"
    @Published var fps:                 Int    = 0
    @Published var axTrusted:           Bool   = false

    weak var renderer: MetalCursorRenderer?

    func toggle() {
        isEnabled.toggle()
        if isEnabled { renderer?.enable() } else { renderer?.disable() }
    }

    func toggleHighPerformance() {
        highPerformanceMode.toggle()
        renderer?.highPerformanceMode = highPerformanceMode
    }
}

// MARK: - Window controller

final class SettingsWindowController {
    private var window: NSPanel?
    private let state:  OverlayState

    init(state: OverlayState) { self.state = state }

    func toggle(relativeTo button: NSStatusBarButton?) {
        if let w = window, w.isVisible {
            w.orderOut(nil)
            return
        }
        show(relativeTo: button)
    }

    private func show(relativeTo button: NSStatusBarButton?) {
        let panel = NSPanel(
            contentRect:  NSRect(x: 0, y: 0, width: 320, height: 1),   // height auto
            styleMask:    [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing:      .buffered,
            defer:        false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility            = .hidden
        panel.isFloatingPanel            = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor            = .clear
        panel.isOpaque                   = false
        panel.hasShadow                  = true
        panel.level                      = .floating
        panel.collectionBehavior         = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = SettingsView(state: state)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        panel.contentView = hosting
        hosting.setFrameSize(hosting.fittingSize)
        panel.setContentSize(hosting.fittingSize)

        // Position below the status bar button, or centered on screen
        if let btn = button, let btnWindow = btn.window {
            let btnRect = btnWindow.convertToScreen(btn.bounds)
            let x = btnRect.midX - panel.frame.width / 2
            let y = btnRect.minY - panel.frame.height - 4
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }

        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}

// MARK: - SwiftUI view

struct SettingsView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassContent(state: state)
        } else {
            FallbackContent(state: state)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(8)
        }
    }
}

// MARK: - macOS 26 liquid glass variant

@available(macOS 26.0, *)
private struct GlassContent: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        ContentBody(state: state)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(8)
    }
}

// MARK: - Fallback (macOS 14–25)

private struct FallbackContent: View {
    @ObservedObject var state: OverlayState
    var body: some View { ContentBody(state: state) }
}

// MARK: - Shared body

private struct ContentBody: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.teal)
                Text("Cursor Overlay")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().padding(.horizontal, 12)

            // ── Toggle ──────────────────────────────────────────────
            HStack {
                Label("Overlay", systemImage: state.isEnabled ? "eye.fill" : "eye.slash")
                    .foregroundStyle(state.isEnabled ? .primary : .secondary)
                Spacer()
                Toggle("", isOn: Binding(get: { state.isEnabled },
                                         set: { _ in state.toggle() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.teal)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().padding(.horizontal, 12)

            // ── High Performance Mode ────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("High Performance", systemImage: "bolt.fill")
                        .foregroundStyle(state.highPerformanceMode ? .yellow : .primary)
                    Spacer()
                    Toggle("", isOn: Binding(get: { state.highPerformanceMode },
                                             set: { _ in state.toggleHighPerformance() }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.yellow)
                }
                Text("Renders on every mouse move for lower latency. May drain battery faster.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().padding(.horizontal, 12)

            // ── Status ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                statusRow(label: "Context", value: state.contextName)
                statusRow(label: "FPS",     value: "\(state.fps)")
                statusRow(label: "Access",  value: state.axTrusted ? "Granted ✓" : "Not granted",
                          valueColor: state.axTrusted ? .green : .orange)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().padding(.horizontal, 12)

            // ── Actions ─────────────────────────────────────────────
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    )
                } label: {
                    Label("Accessibility", systemImage: "lock.shield")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.teal)

                Spacer()

                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 300)
    }

    @ViewBuilder
    private func statusRow(label: String, value: String, valueColor: Color = .secondary) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }
}
