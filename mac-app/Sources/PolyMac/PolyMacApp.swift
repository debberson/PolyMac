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

        Window("Subject Database", id: "subjects") {
            SubjectsWindow(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 960, height: 640)
        .commands { SubjectCommands() }

        Window("Saved Questions", id: "savedQuestions") {
            SavedQuestionsWindow(model: model)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 900, height: 560)
    }
}

private struct SubjectCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Subject Database") { openWindow(id: "subjects") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Saved Questions") { openWindow(id: "savedQuestions") }
        }
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
