import AppKit
import SwiftUI

@main
struct PolyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("PolyMac") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
        }

        Window("Subject", id: "subject") {
            SubjectView(model: model)
                .frame(minWidth: 520, minHeight: 360)
        }
        .defaultSize(width: 760, height: 480)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched via `swift run` there is no app bundle, so opt in to a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
