#if os(macOS)
import AppKit
import SwiftUI
import HearthCore

@MainActor
public final class InstantChatPanelController: NSWindowController, NSWindowDelegate {
    private let model: WorkspaceModel
    private let textView = NSTextView()
    private let replyView = NSTextView()
    private let modelPopup = NSPopUpButton()
    private let agentPopup = NSPopUpButton()
    private let toolsField = NSTextField()
    private var files: [URL] = []
    private var task: Task<Void, Never>?

    public init(model: WorkspaceModel) {
        self.model = model
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Instant Chat"
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = buildContent()
        panel.center()
        reloadPopups()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func present() {
        reloadPopups()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        textView.window?.makeFirstResponder(textView)
    }

    private func buildContent() -> NSView {
        let root = NSView()
        let promptScroll = scroll(textView)
        let replyScroll = scroll(replyView)
        replyView.isEditable = false
        textView.font = NSFont.systemFont(ofSize: 14)
        replyView.font = NSFont.systemFont(ofSize: 13)
        textView.backgroundColor = HearthTheme.paper
        replyView.backgroundColor = HearthTheme.paper
        toolsField.placeholderString = "Enabled tool names, separated by commas"
        let fileButton = NSButton(title: "Add files", target: self, action: #selector(addFiles))
        let sendButton = NSButton(title: "Send", target: self, action: #selector(send))
        let cancelButton = NSButton(title: "Stop", target: self, action: #selector(stop))
        let stack = NSStackView(views: [modelPopup, agentPopup, toolsField, fileButton, promptScroll, sendButton, cancelButton, replyScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        replyScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            promptScroll.heightAnchor.constraint(equalToConstant: 90),
            replyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            promptScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            replyScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return root
    }

    private func scroll(_ textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        return scroll
    }

    private func reloadPopups() {
        modelPopup.removeAllItems()
        for preset in ModelCatalog.presets {
            modelPopup.addItem(withTitle: "\(preset.provider.displayName) · \(preset.name)")
        }
        agentPopup.removeAllItems()
        agentPopup.addItem(withTitle: "No agent")
        for agent in model.agents {
            agentPopup.addItem(withTitle: agent.name)
        }
    }

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        files.append(contentsOf: panel.urls)
    }

    @objc private func stop() {
        task?.cancel()
    }

    @objc private func send() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty else { return }
        let index = modelPopup.indexOfSelectedItem
        let preset = ModelCatalog.presets.indices.contains(index) ? ModelCatalog.presets[index] : .defaultModel
        let agent = agentPopup.indexOfSelectedItem > 0 ? model.agents[safe: agentPopup.indexOfSelectedItem - 1] : nil
        let enabled = toolsField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let workflowFiles = files.map { url -> WorkflowFile in
            let data = (try? Data(contentsOf: url)) ?? Data()
            return FileTextLoader.load(name: url.lastPathComponent, data: data)
        }
        let draft = InstantChatDraft(
            text: text,
            files: workflowFiles,
            agent: agent,
            model: agent?.model ?? preset,
            enabledToolNames: enabled.isEmpty ? (agent?.enabledToolNames ?? []) : enabled,
            allowedTools: enabled.map { ToolDefinition(name: $0, description: $0, jsonSchema: "{\"type\":\"object\"}") }
        )
        let request = draft.makeRequest()
        replyView.string = ""
        task = Task { [weak self] in
            guard let self else { return }
            let credentials = (try? CredentialAccount.credentials(from: self.model.secrets, ollamaBaseURL: self.model.ollamaBaseURL))
                ?? ProviderCredentials(ollamaBaseURL: self.model.ollamaBaseURL)
            let result = await ChatTurnRunner.run(request: request, credentials: credentials, client: URLSessionStreamingClient()) { update in
                Task { @MainActor in
                    self.replyView.string = update.text
                }
            }
            self.replyView.string = result.text.isEmpty ? (result.failure?.displayMessage ?? "") : result.text
            await self.store(result: result, draft: draft)
        }
    }

    private func store(result: StreamSnapshot, draft: InstantChatDraft) async {
        guard let store = await modelStore() else { return }
        let now = Date()
        var project = model.projects.first { $0.name == "Instant" }
        if project == nil {
            project = Project(id: UUID(), name: "Instant", instructions: "", createdAt: now, updatedAt: now)
            if let project {
                try? await store.saveProject(project)
            }
        }
        guard let project else { return }
        let chat = Chat(
            id: UUID(),
            projectID: project.id,
            title: ChatTitle.fromUserText(draft.text),
            agentID: draft.agent?.id,
            model: draft.model,
            createdAt: now,
            updatedAt: now
        )
        try? await store.saveChat(chat)
        try? await store.saveMessage(Message(id: UUID(), chatID: chat.id, role: .user, text: draft.text, status: .complete, createdAt: now, ordinal: 0))
        var assistant = Message(id: UUID(), chatID: chat.id, role: .assistant, text: "", status: .streaming, createdAt: now, ordinal: 1)
        assistant = apply(result, to: assistant)
        try? await store.saveMessage(assistant)
        try? await model.reload()
    }

    private func modelStore() async -> CoreDataChatStore? {
        await model.start()
        return model.openedStore
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
