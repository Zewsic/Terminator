#if !APP_STORE
import AppKit
import SwiftUI
import TerminatorFeatures

@MainActor
enum TerminatorMainWindow {
    private static var window: NSWindow?
    static var model: TerminatorAppModel?

    static var isVisible: Bool { window?.isVisible == true }

    static func reveal() {
        guard let model else { return }
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = RootView()
            .environment(model)
            .frame(minWidth: 1120, minHeight: 768)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.title = "Terminator"
        window.toolbar = nil
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.contentViewController = NSHostingController(rootView: root)
        window.minSize = NSSize(width: 1120, height: 768)
        window.center()
        window.setFrameAutosaveName("TerminatorMain")
        var frame = window.frame
        if frame.width < 1120 || frame.height < 768 {
            frame.size.width = max(frame.size.width, 1120)
            frame.size.height = max(frame.size.height, 768)
            window.setFrame(frame, display: false)
        }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        Self.window = window
        NSApp.activate()
    }
}
#endif
