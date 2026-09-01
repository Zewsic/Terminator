#if os(macOS)
import AppKit
import SwiftUI

/// Keeps the window toolbar visually empty so items sit on the window content.
/// SwiftUI's toolbar-background modifiers often do not stick on an AppKit-hosted window.
struct WindowToolbarChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let apply = {
            guard let window = nsView.window else { return }
            Self.apply(to: window)
        }
        DispatchQueue.main.async(execute: apply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: apply)
    }

    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        hideToolbarFill(in: window.contentView?.superview)
    }

    private static func hideToolbarFill(in view: NSView?) {
        guard let view else { return }
        let name = NSStringFromClass(type(of: view))
        if name.contains("NSToolbarView") {
            for subview in view.subviews {
                let subName = NSStringFromClass(type(of: subview))
                if subName.contains("NSGlass") {
                    subview.isHidden = true
                    subview.alphaValue = 0
                }
            }
        }
        for subview in view.subviews {
            hideToolbarFill(in: subview)
        }
    }
}
#endif
