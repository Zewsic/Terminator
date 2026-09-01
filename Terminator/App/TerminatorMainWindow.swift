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
            .frame(minWidth: 920, minHeight: 620)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
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
        window.center()
        window.setFrameAutosaveName("TerminatorMain")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        Self.window = window
        NSApp.activate()
    }
}
#endif
