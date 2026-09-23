#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = WorkspaceModel()
    private let dictation = DictationController()
    private var instant: InstantChatPanelController?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        dictation.onDeliver = { [weak self] text in
            self?.model.deliverDictation(text)
        }
        dictation.onStatus = { [weak self] text in
            self?.model.statusText = text
        }
        instant = InstantChatPanelController(model: model)
        installMonitors()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    func showInstantChat() {
        instant?.present()
    }

    func toggleDictation() {
        dictation.toggle()
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                _ = self?.handleHotkey(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handleHotkey(event) ?? false
            }
            return handled ? nil : event
        }
    }

    private func handleHotkey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains([.control, .option]), !flags.contains(.command) else { return false }
        switch event.keyCode {
        case 49:
            showInstantChat()
            return true
        case 2:
            toggleDictation()
            return true
        default:
            return false
        }
    }
}

@main
struct HearthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            HearthScreen(model: delegate.model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { delegate.model.newChat() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Project") { delegate.model.newProject(name: "Project", instructions: "") }
            }
            CommandMenu("Workspace") {
                Button("Instant Chat") { delegate.showInstantChat() }
                    .keyboardShortcut(.space, modifiers: [.control, .option])
                Button("Instant Dictation") { delegate.toggleDictation() }
                    .keyboardShortcut("d", modifiers: [.control, .option])
                Divider()
                Button("Agents") { delegate.model.sheet = .agents }
                Button("Saved Prompts") { delegate.model.sheet = .prompts }
                Button("Workflows") { delegate.model.sheet = .workflows }
                Button("MCP Servers") { delegate.model.sheet = .mcp }
                Divider()
                Button("Export Chat…") { delegate.model.exportSelectedChat() }
                Button("Backup…") { delegate.model.backup() }
                Button("Restore…") { delegate.model.restore() }
                Divider()
                Button("Seed Large History") { delegate.model.seedLargeHistory() }
                Button("Settings") { delegate.model.sheet = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
#endif
