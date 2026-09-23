#if os(macOS)
import AppKit
import Foundation
import HearthCore
import UniformTypeIdentifiers

@MainActor
public final class WorkspaceModel: ObservableObject {
    @Published public var sidebarRows: [SidebarEntry] = []
    @Published public var messages: [Message] = []
    @Published public var projects: [Project] = []
    @Published public var chats: [Chat] = []
    @Published public var agents: [Agent] = []
    @Published public var prompts: [SavedPrompt] = []
    @Published public var workflows: [Workflow] = []
    @Published public var mcpServers: [MCPServer] = []
    @Published public var selectedChatID: UUID?
    @Published public var selectedProjectID: UUID?
    @Published public var statusText = "Ready"
    @Published public var phase: StreamPhase = .idle
    @Published public var transcriptGeneration = 0
    @Published public var scrollTarget: UUID?
    @Published public var sheet: LibrarySheet?
    @Published public var dictationText = ""
    @Published public var performanceSummary = ""

    public let probe = PerformanceProbe()
    public let secrets = KeychainSecretStore()
    public var currentSelection = ""
    public var collapsedProjects: Set<UUID> = []
    public var searchFilter = ""

    private var store: CoreDataChatStore?
    public var openedStore: CoreDataChatStore? { store }
    private var snapshot = WorkspaceSnapshot.empty
    private var streamTask: Task<Void, Never>?
    private var started = false
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("Hearth", isDirectory: true)
        }
    }

    public func start() async {
        guard !started else { return }
        started = true
        do {
            let store = try await CoreDataChatStore(directory: directory)
            self.store = store
            _ = try await store.ensureFirstRun(now: Date())
            let recovered = try await store.recoverInterruptedStreams()
            if !recovered.isEmpty {
                statusText = "Restored \(recovered.count) interrupted response\(recovered.count == 1 ? "" : "s")."
            }
            try await reload()
            if selectedChatID == nil {
                selectedChatID = snapshot.chats.first?.id
                selectedProjectID = snapshot.chats.first?.projectID
                loadMessages()
            }
        } catch {
            statusText = "Could not open the local store."
        }
    }

    public func reload() async throws {
        guard let store else { return }
        let started = ContinuousClock.now
        snapshot = try await store.snapshot()
        projects = snapshot.projects
        chats = snapshot.chats
        agents = snapshot.agents
        prompts = snapshot.prompts
        workflows = snapshot.workflows
        mcpServers = snapshot.mcpServers
        sidebarRows = SidebarLayout.rows(
            projects: projects,
            chats: chats,
            collapsed: collapsedProjects,
            filter: searchFilter
        )
        probe.record(.navigation, milliseconds: milliseconds(since: started))
    }

    public func selectSidebar(_ entry: SidebarEntry) {
        let started = ContinuousClock.now
        switch entry.kind {
        case .project(let id):
            if collapsedProjects.contains(id) {
                collapsedProjects.remove(id)
            } else {
                collapsedProjects.insert(id)
            }
            selectedProjectID = id
            sidebarRows = SidebarLayout.rows(projects: projects, chats: chats, collapsed: collapsedProjects, filter: searchFilter)
        case .chat(let id):
            selectedChatID = id
            selectedProjectID = chats.first { $0.id == id }?.projectID
            loadMessages()
        case .searchHit(let messageID, let chatID):
            selectedChatID = chatID
            loadMessages()
            scrollTarget = messageID
        }
        probe.record(.navigation, milliseconds: milliseconds(since: started))
    }

    public func updateFilter(_ text: String) {
        searchFilter = text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sidebarRows = SidebarLayout.rows(projects: projects, chats: chats, collapsed: collapsedProjects, filter: "")
            return
        }
        let hits = SearchRanking.hits(in: snapshot.messages, query: text, limit: 30)
        if hits.isEmpty {
            sidebarRows = SidebarLayout.rows(projects: projects, chats: chats, collapsed: collapsedProjects, filter: text)
            return
        }
        sidebarRows = hits.map { hit in
            let title = chats.first { $0.id == hit.chatID }?.title ?? "Chat"
            return SidebarEntry(
                id: "hit-\(hit.messageID.uuidString)",
                kind: .searchHit(messageID: hit.messageID, chatID: hit.chatID),
                title: title,
                subtitle: hit.snippet,
                depth: 0
            )
        }
    }

    public func newProject(name: String, instructions: String) {
        Task { await self.createProject(name: name, instructions: instructions) }
    }

    public func newChat() {
        Task { await self.createChat() }
    }

    public func send(draft: String, fileURLs: [URL]) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !fileURLs.isEmpty else { return }
        streamTask?.cancel()
        streamTask = Task { await self.performSend(text: text, fileURLs: fileURLs) }
    }

    public func cancelStreaming() {
        streamTask?.cancel()
    }

    public func retry() {
        streamTask = Task { await self.performRetry() }
    }

    public func regenerate() {
        streamTask = Task { await self.performRegenerate() }
    }

    public func forkSelected(messageID: UUID?) {
        Task { await self.performFork(messageID: messageID) }
    }

    public func saveAgent(_ agent: Agent) {
        Task {
            try? await self.store?.saveAgent(agent)
            try? await self.reload()
        }
    }

    public func savePrompt(_ prompt: SavedPrompt) {
        Task {
            try? await self.store?.savePrompt(prompt)
            try? await self.reload()
        }
    }

    public func saveWorkflow(_ workflow: Workflow) {
        Task {
            try? await self.store?.saveWorkflow(workflow)
            try? await self.reload()
        }
    }

    public func saveMCPServer(_ server: MCPServer) {
        Task {
            try? await self.store?.saveMCPServer(server)
            try? await self.reload()
        }
    }

    public func runWorkflow(_ workflow: Workflow, fileURLs: [URL]) {
        let files = fileURLs.map { url -> WorkflowFile in
            let data = (try? Data(contentsOf: url)) ?? Data()
            return FileTextLoader.load(name: url.lastPathComponent, data: data)
        }
        let inputs = WorkflowInputs(
            selection: currentSelection,
            clipboard: NSPasteboard.general.string(forType: .string),
            files: files
        )
        let agent = agents.first { $0.id == workflow.agentID }
        do {
            let resolved = try WorkflowEngine.resolve(
                workflow: workflow,
                prompt: prompts.first { $0.title == workflow.name },
                agent: agent,
                inputs: inputs,
                fallbackModel: selectedChat?.model ?? .defaultModel
            )
            send(draft: resolved.prompt, fileURLs: [])
        } catch {
            statusText = workflowErrorText(error)
        }
    }

    public func exportSelectedChat() {
        Task { await self.performExport() }
    }

    public func backup() {
        Task { await self.performBackup() }
    }

    public func restore() {
        Task { await self.performRestore() }
    }

    public func seedLargeHistory() {
        Task { await self.performSeed() }
    }

    public func refreshPerformanceSummary() {
        let report = probe.report()
        performanceSummary = InteractionKind.allCases.map { kind in
            let average = report.averageMilliseconds(for: kind).map { String(format: "%.2f ms", $0) } ?? "—"
            return "\(kind.rawValue): \(average)"
        }.joined(separator: "\n")
    }

    public func saveSecret(account: String, secret: String) {
        guard !secret.isEmpty else { return }
        do {
            try secrets.save(account: account, secret: secret)
            statusText = "Saved the key in the Keychain."
        } catch {
            statusText = "Could not save the key in the Keychain."
        }
    }

    public func hasSecret(_ account: String) -> Bool {
        ((try? secrets.load(account: account)) ?? nil)?.isEmpty == false
    }

    public var ollamaBaseURL: URL {
        get {
            if let raw = UserDefaults.standard.string(forKey: "hearth.ollamaBaseURL"), let url = URL(string: raw) {
                return url
            }
            return URL(string: "http://127.0.0.1:11434")!
        }
        set {
            UserDefaults.standard.set(newValue.absoluteString, forKey: "hearth.ollamaBaseURL")
        }
    }

    public var selectedChat: Chat? {
        chats.first { $0.id == selectedChatID }
    }

    public func deliverDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        statusText = "Inserted dictation."
        send(draft: trimmed, fileURLs: [])
    }

    public func imageAttachmentData(id: UUID) -> Data? {
        guard let attachment = snapshot.attachments.first(where: { $0.id == id }), attachment.isImage else { return nil }
        return try? Data(contentsOf: StoreLayout.attachmentURL(directory, id: id))
    }

    public func renderedImageCount(for message: Message) -> Int {
        let markdownImages = MarkdownParser.parse(message.text).reduce(into: 0) { count, block in
            if case .image = block { count += 1 }
        }
        let attached = message.attachmentIDs.filter { id in
            snapshot.attachments.contains { $0.id == id && $0.isImage }
        }.count
        return markdownImages + attached
    }

    private func loadMessages() {
        guard let selectedChatID else {
            messages = []
            return
        }
        messages = snapshot.messages.filter { $0.chatID == selectedChatID }.sorted { $0.ordinal < $1.ordinal }
        phase = messages.last?.status == .streaming ? .streaming : .idle
        transcriptGeneration += 1
    }

    private func createProject(name: String, instructions: String) async {
        let now = Date()
        let project = Project(id: UUID(), name: name.isEmpty ? "Project" : name, instructions: instructions, createdAt: now, updatedAt: now)
        do {
            try await store?.saveProject(project)
            selectedProjectID = project.id
            try await reload()
        } catch {
            statusText = "Could not create the project."
        }
    }

    private func createChat() async {
        guard let projectID = selectedProjectID ?? projects.first?.id else { return }
        let now = Date()
        let chat = Chat(
            id: UUID(),
            projectID: projectID,
            title: "New chat",
            agentID: agents.first?.id,
            model: agents.first?.model ?? .defaultModel,
            createdAt: now,
            updatedAt: now
        )
        do {
            try await store?.saveChat(chat)
            selectedChatID = chat.id
            try await reload()
            loadMessages()
        } catch {
            statusText = "Could not create the chat."
        }
    }

    private func performSend(text: String, fileURLs: [URL]) async {
        guard let store, let chatID = selectedChatID ?? await makeChatIfNeeded() else { return }
        do {
            var attachmentIDs: [UUID] = []
            for url in fileURLs {
                let data = try Data(contentsOf: url)
                let attachment = Attachment(
                    id: UUID(),
                    filename: url.lastPathComponent,
                    mimeType: mimeType(for: url),
                    byteCount: data.count,
                    relativePath: ""
                )
                try await store.saveAttachment(attachment, data: data)
                attachmentIDs.append(attachment.id)
            }
            let current = try await store.snapshot()
            let change = try TurnPreparation.beginSend(
                snapshot: current,
                chatID: chatID,
                userText: text,
                attachmentIDs: attachmentIDs,
                now: Date()
            )
            try await store.apply(change)
            try await reload()
            selectedChatID = chatID
            loadMessages()
            await stream(change: change)
        } catch {
            statusText = "Could not send the message."
        }
    }

    private func performRetry() async {
        guard let store, let chatID = selectedChatID else { return }
        do {
            let change = try TurnPreparation.retry(snapshot: try await store.snapshot(), chatID: chatID, now: Date())
            try await store.apply(change)
            try await reload()
            loadMessages()
            await stream(change: change)
        } catch {
            statusText = "There is no failed response to retry."
        }
    }

    private func performRegenerate() async {
        guard let store, let chatID = selectedChatID else { return }
        do {
            let change = try TurnPreparation.regenerate(snapshot: try await store.snapshot(), chatID: chatID, now: Date())
            try await store.apply(change)
            try await reload()
            loadMessages()
            await stream(change: change)
        } catch {
            statusText = "There is no response to regenerate."
        }
    }

    private func stream(change: TurnChange) async {
        guard let store else { return }
        let started = ContinuousClock.now
        phase = .streaming
        statusText = "Streaming"
        let credentials = (try? CredentialAccount.credentials(from: secrets, ollamaBaseURL: ollamaBaseURL))
            ?? ProviderCredentials(ollamaBaseURL: ollamaBaseURL)
        let current = snapshot
        let chat = change.chat
        let project = current.projects.first { $0.id == chat.projectID }
        let agent = current.agents.first { $0.id == chat.agentID }
        var tools: [ToolDefinition] = []
        if let agent {
            tools = await toolsForAgent(agent)
        }
        var bytes: [UUID: Data] = [:]
        for message in change.contextMessages {
            for id in message.attachmentIDs {
                if let data = try? await store.dataForAttachment(id) {
                    bytes[id] = data
                }
            }
        }
        let request = PromptAssembly.request(
            chat: chat,
            project: project,
            agent: agent,
            messages: change.contextMessages,
            attachments: current.attachments,
            attachmentBytes: bytes,
            tools: tools
        )
        let assistantID = change.assistantMessage.id
        let snapshotResult = await ChatTurnRunner.run(
            request: request,
            credentials: credentials,
            client: URLSessionStreamingClient()
        ) { [weak self] update in
            Task { @MainActor in
                await self?.applyPartial(update, assistantID: assistantID)
            }
        }
        await applyPartial(snapshotResult, assistantID: assistantID)
        phase = snapshotResult.phase
        statusText = snapshotResult.failure?.displayMessage ?? statusTextFor(snapshotResult.phase)
        probe.record(.streaming, milliseconds: milliseconds(since: started))
        refreshPerformanceSummary()
    }

    private func applyPartial(_ update: StreamSnapshot, assistantID: UUID) async {
        guard let store else { return }
        guard var message = messages.first(where: { $0.id == assistantID }) ?? snapshot.messages.first(where: { $0.id == assistantID }) else {
            return
        }
        message = apply(update, to: message)
        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index] = message
        }
        transcriptGeneration += 1
        try? await store.saveMessage(message)
        if let index = snapshot.messages.firstIndex(where: { $0.id == assistantID }) {
            snapshot.messages[index] = message
        }
    }

    private func toolsForAgent(_ agent: Agent) async -> [ToolDefinition] {
        var collected: [MCPTool] = []
        for server in mcpServers where agent.mcpServerIDs.contains(server.id) && server.enabled {
            let transport: (any MCPTransport)?
            switch server.transport {
            case .stdio:
                guard let command = server.command else { continue }
                transport = try? MCPStdioTransport(command: command, arguments: server.arguments)
            case .http:
                guard let raw = server.url, let url = URL(string: raw) else { continue }
                transport = MCPHTTPTransport(url: url)
            }
            guard let transport else { continue }
            let client = MCPClient(transport: transport)
            if let tools = try? await client.listTools() {
                collected.append(contentsOf: tools)
            }
            (transport as? MCPStdioTransport)?.terminate()
        }
        return ToolCatalog.definitions(from: ToolCatalog.filtered(collected, enabledNames: agent.enabledToolNames))
    }

    private func performFork(messageID: UUID?) async {
        guard let store, let chatID = selectedChatID else { return }
        let messages = self.messages
        let pivot = messageID ?? messages.last?.id
        guard let pivot else { return }
        do {
            let chat = try await store.forkChat(chatID, through: pivot, now: Date())
            selectedChatID = chat.id
            try await reload()
            loadMessages()
            statusText = "Forked the chat."
        } catch {
            statusText = "Could not fork the chat."
        }
    }

    private func performExport() async {
        guard let store, let chatID = selectedChatID else { return }
        do {
            let data = try await store.exportChat(chatID)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "hearth-chat.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            statusText = "Exported the chat."
        } catch {
            statusText = "Could not export the chat."
        }
    }

    private func performBackup() async {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let destination = url.appendingPathComponent("Hearth Backup \(Int(Date().timeIntervalSince1970))", isDirectory: true)
            try await store.backup(to: destination, now: Date())
            statusText = "Wrote a local backup."
        } catch {
            statusText = "Could not write the backup."
        }
    }

    private func performRestore() async {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await store.restore(from: url)
            try await reload()
            selectedChatID = chats.first?.id
            loadMessages()
            statusText = "Restored the backup."
        } catch {
            statusText = "Could not restore the backup."
        }
    }

    private func performSeed() async {
        guard let store else { return }
        let now = Date()
        let project = Project(id: UUID(), name: "Performance", instructions: "", createdAt: now, updatedAt: now)
        let chat = Chat(id: UUID(), projectID: project.id, title: "Large history", model: .defaultModel, createdAt: now, updatedAt: now)
        do {
            try await store.saveProject(project)
            try await store.saveChat(chat)
            for message in HistorySeeder.messages(chatID: chat.id, count: 5_000, now: now) {
                try await store.saveMessage(message)
            }
            selectedChatID = chat.id
            selectedProjectID = project.id
            try await reload()
            loadMessages()
            statusText = "Seeded 5,000 messages for profiling."
        } catch {
            statusText = "Could not seed the history."
        }
    }

    private func makeChatIfNeeded() async -> UUID? {
        if let selectedChatID { return selectedChatID }
        await createChat()
        return selectedChatID
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "md": "text/markdown"
        default: "text/plain"
        }
    }

    private func statusTextFor(_ phase: StreamPhase) -> String {
        switch phase {
        case .completed: "Completed"
        case .cancelled: "Cancelled. The partial response was kept."
        case .interrupted: "Stream interrupted. The partial response was kept."
        case .failed: "The provider request failed."
        case .streaming: "Streaming"
        case .idle: "Ready"
        }
    }

    private func workflowErrorText(_ error: Error) -> String {
        switch error as? WorkflowError {
        case .missingSelection: "Select text before running this workflow."
        case .missingClipboard: "Copy text before running this workflow."
        case .missingFiles: "Choose files before running this workflow."
        case .emptyResolvedPrompt: "The workflow prompt was empty."
        case nil: "Could not run the workflow."
        }
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
    }
}

public enum LibrarySheet: String, Identifiable {
    case agents, prompts, workflows, mcp, settings
    public var id: String { rawValue }
}
#endif
