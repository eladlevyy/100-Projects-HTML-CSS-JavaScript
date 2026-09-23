import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable, Equatable {
    case openAI = "openai"
    case anthropic
    case gemini
    case ollama

    public var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        case .ollama: "Ollama"
        }
    }
}

public struct ModelRef: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var provider: ProviderKind
    public var name: String

    public var id: String { "\(provider.rawValue):\(name)" }

    public init(provider: ProviderKind, name: String) {
        self.provider = provider
        self.name = name
    }

    public static let defaultModel = ModelRef(provider: .ollama, name: "llama3.2")
}

public enum ModelCatalog {
    public static let presets: [ModelRef] = [
        ModelRef(provider: .openAI, name: "gpt-4o"),
        ModelRef(provider: .openAI, name: "gpt-4o-mini"),
        ModelRef(provider: .anthropic, name: "claude-sonnet-4-5"),
        ModelRef(provider: .anthropic, name: "claude-haiku-4-5"),
        ModelRef(provider: .gemini, name: "gemini-2.5-flash"),
        ModelRef(provider: .gemini, name: "gemini-2.5-pro"),
        ModelRef(provider: .ollama, name: "llama3.2"),
    ]

    public static let defaultModel = ModelRef(provider: .ollama, name: "llama3.2")
}

public enum MessageRole: String, Codable, Sendable, Equatable {
    case system
    case user
    case assistant
    case tool
}

public enum MessageStatus: String, Codable, Sendable, Equatable {
    case complete
    case streaming
    case partial
    case cancelled
    case failed
    case interrupted
}

public struct Citation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String?
    public var url: String?
    public var snippet: String?

    public init(id: UUID = UUID(), title: String? = nil, url: String? = nil, snippet: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public struct ToolCallDraft: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: String
    public var output: String
    public var isError: Bool

    public init(id: String, name: String, arguments: String, output: String, isError: Bool) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.output = output
        self.isError = isError
    }
}

public struct Attachment: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var byteCount: Int
    public var relativePath: String

    public init(id: UUID, filename: String, mimeType: String, byteCount: Int, relativePath: String) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.relativePath = relativePath
    }

    public var isImage: Bool {
        mimeType.hasPrefix("image/")
    }
}

public struct Message: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var chatID: UUID
    public var role: MessageRole
    public var text: String
    public var reasoning: String
    public var status: MessageStatus
    public var errorMessage: String?
    public var retryable: Bool
    public var citations: [Citation]
    public var toolCalls: [ToolCallDraft]
    public var toolResults: [ToolResult]
    public var attachmentIDs: [UUID]
    public var createdAt: Date
    public var ordinal: Int

    public init(
        id: UUID,
        chatID: UUID,
        role: MessageRole,
        text: String,
        reasoning: String = "",
        status: MessageStatus,
        errorMessage: String? = nil,
        retryable: Bool = false,
        citations: [Citation] = [],
        toolCalls: [ToolCallDraft] = [],
        toolResults: [ToolResult] = [],
        attachmentIDs: [UUID] = [],
        createdAt: Date,
        ordinal: Int
    ) {
        self.id = id
        self.chatID = chatID
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.status = status
        self.errorMessage = errorMessage
        self.retryable = retryable
        self.citations = citations
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.attachmentIDs = attachmentIDs
        self.createdAt = createdAt
        self.ordinal = ordinal
    }

    public var hasRecoverableContent: Bool {
        !text.isEmpty || !reasoning.isEmpty || !toolCalls.isEmpty || !toolResults.isEmpty
    }
}

public struct Chat: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var projectID: UUID
    public var title: String
    public var agentID: UUID?
    public var model: ModelRef
    public var createdAt: Date
    public var updatedAt: Date
    public var forkedFromChatID: UUID?
    public var forkedFromMessageID: UUID?

    public init(
        id: UUID,
        projectID: UUID,
        title: String,
        agentID: UUID? = nil,
        model: ModelRef,
        createdAt: Date,
        updatedAt: Date,
        forkedFromChatID: UUID? = nil,
        forkedFromMessageID: UUID? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.agentID = agentID
        self.model = model
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.forkedFromChatID = forkedFromChatID
        self.forkedFromMessageID = forkedFromMessageID
    }
}

public struct Project: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var instructions: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, name: String, instructions: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Agent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var systemPrompt: String
    public var model: ModelRef
    public var temperature: Double?
    public var enabledToolNames: [String]
    public var mcpServerIDs: [UUID]

    public init(
        id: UUID,
        name: String,
        systemPrompt: String,
        model: ModelRef,
        temperature: Double? = nil,
        enabledToolNames: [String] = [],
        mcpServerIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
        self.model = model
        self.temperature = temperature
        self.enabledToolNames = enabledToolNames
        self.mcpServerIDs = mcpServerIDs
    }
}

public struct SavedPrompt: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var body: String
    public var createdAt: Date

    public init(id: UUID, title: String, body: String, createdAt: Date) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
    }
}

public enum WorkflowInputSource: String, Codable, Sendable, CaseIterable, Equatable {
    case selection
    case clipboard
    case files
}

public struct Workflow: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var template: String
    public var sources: [WorkflowInputSource]
    public var agentID: UUID?
    public var model: ModelRef?

    public init(
        id: UUID,
        name: String,
        template: String,
        sources: [WorkflowInputSource],
        agentID: UUID? = nil,
        model: ModelRef? = nil
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.sources = sources
        self.agentID = agentID
        self.model = model
    }
}

public enum MCPTransportKind: String, Codable, Sendable, Equatable {
    case stdio
    case http
}

public struct MCPServer: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var transport: MCPTransportKind
    public var command: String?
    public var arguments: [String]
    public var url: String?
    public var enabled: Bool

    public init(
        id: UUID,
        name: String,
        transport: MCPTransportKind,
        command: String? = nil,
        arguments: [String] = [],
        url: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.url = url
        self.enabled = enabled
    }
}

public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
    public static let currentFormat = 1

    public var format: Int
    public var projects: [Project]
    public var chats: [Chat]
    public var messages: [Message]
    public var attachments: [Attachment]
    public var agents: [Agent]
    public var prompts: [SavedPrompt]
    public var workflows: [Workflow]
    public var mcpServers: [MCPServer]

    public init(
        format: Int = WorkspaceSnapshot.currentFormat,
        projects: [Project] = [],
        chats: [Chat] = [],
        messages: [Message] = [],
        attachments: [Attachment] = [],
        agents: [Agent] = [],
        prompts: [SavedPrompt] = [],
        workflows: [Workflow] = [],
        mcpServers: [MCPServer] = []
    ) {
        self.format = format
        self.projects = projects
        self.chats = chats
        self.messages = messages
        self.attachments = attachments
        self.agents = agents
        self.prompts = prompts
        self.workflows = workflows
        self.mcpServers = mcpServers
    }

    public static let empty = WorkspaceSnapshot()
}

public struct SidebarEntry: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case project(UUID)
        case chat(UUID)
        case searchHit(messageID: UUID, chatID: UUID)
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var depth: Int

    public init(id: String, kind: Kind, title: String, subtitle: String = "", depth: Int) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.depth = depth
    }
}

public enum SidebarLayout {
    public static func rows(
        projects: [Project],
        chats: [Chat],
        collapsed: Set<UUID>,
        filter: String
    ) -> [SidebarEntry] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let orderedProjects = projects.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        var rows: [SidebarEntry] = []
        for project in orderedProjects {
            let projectChats = chats
                .filter { $0.projectID == project.id }
                .sorted { $0.updatedAt > $1.updatedAt }
            let visibleChats: [Chat]
            if needle.isEmpty {
                visibleChats = projectChats
            } else {
                let projectMatches = project.name.lowercased().contains(needle)
                visibleChats = projectChats.filter { chat in
                    projectMatches || chat.title.lowercased().contains(needle)
                }
            }
            if !needle.isEmpty && visibleChats.isEmpty {
                continue
            }
            rows.append(
                SidebarEntry(
                    id: "project-\(project.id.uuidString)",
                    kind: .project(project.id),
                    title: project.name,
                    subtitle: "\(projectChats.count)",
                    depth: 0
                )
            )
            if collapsed.contains(project.id) && needle.isEmpty {
                continue
            }
            for chat in visibleChats {
                rows.append(
                    SidebarEntry(
                        id: "chat-\(chat.id.uuidString)",
                        kind: .chat(chat.id),
                        title: chat.title,
                        subtitle: chat.model.name,
                        depth: 1
                    )
                )
            }
        }
        return rows
    }
}

public enum FirstRun {
    public static func bootstrap(now: Date) -> WorkspaceSnapshot {
        let projectID = UUID()
        let agentID = UUID()
        let chatID = UUID()
        let project = Project(
            id: projectID,
            name: "Inbox",
            instructions: "",
            createdAt: now,
            updatedAt: now
        )
        let agent = Agent(
            id: agentID,
            name: "General",
            systemPrompt: "You are a careful assistant inside Hearth, a local Mac workspace. Answer directly. Use tools only when they are provided.",
            model: ModelCatalog.defaultModel,
            temperature: nil,
            enabledToolNames: [],
            mcpServerIDs: []
        )
        let chat = Chat(
            id: chatID,
            projectID: projectID,
            title: "Welcome",
            agentID: agentID,
            model: ModelCatalog.defaultModel,
            createdAt: now,
            updatedAt: now
        )
        let message = Message(
            id: UUID(),
            chatID: chatID,
            role: .assistant,
            text: """
            Hearth keeps this workspace on your Mac.

            Add provider keys in Settings. They are stored in the macOS Keychain and stay out of chats, exports, and backups. Ollama can be used at its local address without a key.

            Projects, agents, prompts, and workflows live in the sidebar. Fork a chat when you want a branch. Search looks through message text on disk.
            """,
            status: .complete,
            createdAt: now,
            ordinal: 0
        )
        return WorkspaceSnapshot(
            projects: [project],
            chats: [chat],
            messages: [message],
            agents: [agent]
        )
    }
}

public enum ChatTitle {
    public static func fromUserText(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return "New chat" }
        if collapsed.count <= 48 { return collapsed }
        let index = collapsed.index(collapsed.startIndex, offsetBy: 48)
        return String(collapsed[..<index]).trimmingCharacters(in: .whitespaces) + "…"
    }
}
