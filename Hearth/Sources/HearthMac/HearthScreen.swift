#if os(macOS)
import AppKit
import SwiftUI
import HearthCore

public struct HearthScreen: View {
    @ObservedObject var model: WorkspaceModel

    public init(model: WorkspaceModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hearth")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(Color(nsColor: HearthTheme.ink))
                Text("Local workspace")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: HearthTheme.ink).opacity(0.7))
                TextField("Search chats", text: Binding(
                    get: { model.searchFilter },
                    set: { model.updateFilter($0) }
                ))
                .textFieldStyle(.roundedBorder)
                SidebarRepresentable(model: model)
                    .equatable()
                HStack {
                    Button("Project") { model.newProject(name: "Project", instructions: "") }
                    Button("Chat") { model.newChat() }
                }
                .buttonStyle(.bordered)
            }
            .padding(12)
            .frame(width: 280)
            .background(Color(nsColor: HearthTheme.sidebar))

            VStack(spacing: 0) {
                HStack {
                    Text(model.selectedChat?.title ?? "No chat")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Retry") { model.retry() }
                    Button("Regenerate") { model.regenerate() }
                    Button("Fork") { model.forkSelected(messageID: model.messages.last?.id) }
                    if model.phase == .streaming {
                        Button("Stop") { model.cancelStreaming() }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                ConversationRepresentable(model: model)
                    .equatable()
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ComposerRepresentable(model: model)
                        .equatable()
                        .frame(height: 110)
                    HStack {
                        Button("Attach") { attachFiles() }
                        Text("Command-Return to send")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: HearthTheme.ink).opacity(0.55))
                        Spacer()
                        Text(model.statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: HearthTheme.ink).opacity(0.7))
                            .lineLimit(2)
                        Button("Send") {
                            NotificationCenter.default.post(name: .hearthSubmitComposer, object: nil)
                        }
                    }
                }
                .padding(12)
            }
            .background(Color(nsColor: HearthTheme.paper))
        }
        .frame(minWidth: 960, minHeight: 640)
        .task { await model.start() }
        .sheet(item: $model.sheet) { sheet in
            LibrarySheetView(model: model, sheet: sheet)
                .frame(minWidth: 520, minHeight: 420)
        }
    }

    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        model.send(draft: "Attached files.", fileURLs: panel.urls)
    }
}

struct LibrarySheetView: View {
    @ObservedObject var model: WorkspaceModel
    let sheet: LibrarySheet
    @State private var name = ""
    @State private var bodyText = ""
    @State private var openAI = ""
    @State private var anthropic = ""
    @State private var gemini = ""
    @State private var ollama = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2)
            switch sheet {
            case .agents:
                editor("New agent", "System prompt") {
                    model.saveAgent(Agent(
                        id: UUID(),
                        name: name.isEmpty ? "Agent" : name,
                        systemPrompt: bodyText,
                        model: model.selectedChat?.model ?? .defaultModel
                    ))
                }
                ForEach(model.agents) { agent in
                    Text("\(agent.name) · \(agent.model.provider.displayName) \(agent.model.name)")
                }
            case .prompts:
                editor("New prompt", "Prompt body. Use {{selection}}, {{clipboard}}, or {{files}}.") {
                    model.savePrompt(SavedPrompt(id: UUID(), title: name.isEmpty ? "Prompt" : name, body: bodyText, createdAt: Date()))
                }
                ForEach(model.prompts) { prompt in
                    Text(prompt.title)
                }
            case .workflows:
                editor("New workflow", "Template") {
                    model.saveWorkflow(Workflow(
                        id: UUID(),
                        name: name.isEmpty ? "Workflow" : name,
                        template: bodyText,
                        sources: [.selection, .clipboard, .files],
                        agentID: model.agents.first?.id
                    ))
                }
                ForEach(model.workflows) { workflow in
                    HStack {
                        Text(workflow.name)
                        Spacer()
                        Button("Run") { model.runWorkflow(workflow, fileURLs: []) }
                    }
                }
            case .mcp:
                editor("MCP server", "stdio command, or http URL") {
                    let isHTTP = bodyText.hasPrefix("http")
                    model.saveMCPServer(MCPServer(
                        id: UUID(),
                        name: name.isEmpty ? "Server" : name,
                        transport: isHTTP ? .http : .stdio,
                        command: isHTTP ? nil : "/bin/sh",
                        arguments: isHTTP ? [] : ["-lc", bodyText],
                        url: isHTTP ? bodyText : nil
                    ))
                }
                ForEach(model.mcpServers) { server in
                    Text("\(server.name) · \(server.transport.rawValue)")
                }
            case .settings:
                SecureField("OpenAI API key", text: $openAI)
                SecureField("Anthropic API key", text: $anthropic)
                SecureField("Gemini API key", text: $gemini)
                TextField("Ollama base URL", text: $ollama)
                Button("Save keys to Keychain") {
                    model.saveSecret(account: CredentialAccount.openAI, secret: openAI)
                    model.saveSecret(account: CredentialAccount.anthropic, secret: anthropic)
                    model.saveSecret(account: CredentialAccount.gemini, secret: gemini)
                    if let url = URL(string: ollama), !ollama.isEmpty {
                        model.ollamaBaseURL = url
                    }
                    openAI = ""
                    anthropic = ""
                    gemini = ""
                }
                Text(model.hasSecret(CredentialAccount.openAI) ? "OpenAI key is in the Keychain." : "No OpenAI key saved.")
                Text(model.hasSecret(CredentialAccount.anthropic) ? "Anthropic key is in the Keychain." : "No Anthropic key saved.")
                Text(model.hasSecret(CredentialAccount.gemini) ? "Gemini key is in the Keychain." : "No Gemini key saved.")
                Text("Data folder\n\(model.directory.path)")
                    .font(.system(size: 12, design: .monospaced))
                Text(model.performanceSummary.isEmpty ? "Performance samples appear after you navigate, type, scroll, or stream." : model.performanceSummary)
                    .font(.system(size: 12, design: .monospaced))
            }
            Spacer()
            Button("Close") { model.sheet = nil }
        }
        .padding(20)
        .onAppear {
            ollama = model.ollamaBaseURL.absoluteString
            model.refreshPerformanceSummary()
        }
    }

    private var title: String {
        switch sheet {
        case .agents: "Agents"
        case .prompts: "Saved prompts"
        case .workflows: "Workflows"
        case .mcp: "MCP servers"
        case .settings: "Settings"
        }
    }

    @ViewBuilder
    private func editor(_ nameLabel: String, _ bodyLabel: String, save: @escaping () -> Void) -> some View {
        TextField(nameLabel, text: $name)
        TextField(bodyLabel, text: $bodyText, axis: .vertical)
            .lineLimit(3...6)
        Button("Save") { save() }
    }
}
#endif
