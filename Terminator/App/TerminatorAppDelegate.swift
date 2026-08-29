import AppKit
#if !APP_STORE
import CoreServices
import CoreSpotlight
import TerminatorCore
#endif

enum TerminatorGUIActions {
    static var connectHost: (@MainActor (UUID) -> Void)?
    static var revealMain: (@MainActor () -> Void)?
}

final class TerminatorAppDelegate: NSObject, NSApplicationDelegate {
    #if !APP_STORE
    private var ignoreNextReopen = false
    #endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if !APP_STORE
        NSApp.setActivationPolicy(.accessory)
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if APP_STORE
        return
        #else
        ConnectionServiceSupport.bootstrap()
        MCPAccessSupport.refreshIfEnabled()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(TerminatorDistributedNotification.revealGUI),
            object: nil,
            queue: .main
        ) { _ in
            TerminatorGUIActions.revealMain?()
        }
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            TerminatorGUIActions.revealMain?()
            return
        }
        if isExternalConnectLaunch {
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if ignoreNextReopen { return }
            TerminatorGUIActions.revealMain?()
        }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        #if !APP_STORE
        ignoreNextReopen = true
        for url in urls { handleConnectURL(url) }
        #endif
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        #if !APP_STORE
        guard userActivity.activityType == CSSearchableItemActionType,
              let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let hostID = SpotlightHostIndexer().hostID(for: identifier) else { return false }
        ignoreNextReopen = true
        guard AccessPreferencesStore.load().cliEnabled else { return true }
        TerminatorGUIActions.connectHost?(hostID)
        return true
        #else
        return false
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        #if !APP_STORE
        if ignoreNextReopen {
            ignoreNextReopen = false
            return false
        }
        TerminatorGUIActions.revealMain?()
        #endif
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    #if !APP_STORE
    private var isExternalConnectLaunch: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventClass == AEEventClass(kInternetEventClass) { return true }
        if event?.eventID == AEEventID(kAEGetURL) { return true }
        return false
    }

    private func handleConnectURL(_ url: URL) {
        guard url.scheme?.lowercased() == "terminator",
              url.host?.lowercased() == "connect",
              let hostID = UUID(uuidString: url.pathComponents.dropFirst().first ?? "") else { return }
        guard AccessPreferencesStore.load().cliEnabled else { return }
        TerminatorGUIActions.connectHost?(hostID)
    }
    #endif
}
