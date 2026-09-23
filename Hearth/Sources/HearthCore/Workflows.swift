import Foundation

public struct WorkflowFile: Sendable, Equatable {
    public var name: String
    public var text: String?
    public var unsupportedReason: String?

    public init(name: String, text: String? = nil, unsupportedReason: String? = nil) {
        self.name = name
        self.text = text
        self.unsupportedReason = unsupportedReason
    }
}

public enum FileTextLoader {
    public static func load(name: String, data: Data, mimeType: String? = nil) -> WorkflowFile {
        if let mimeType, mimeType.hasPrefix("image/") {
            return WorkflowFile(name: name, unsupportedReason: "Image files are attached separately.")
        }
        if let text = String(data: data, encoding: .utf8), !text.contains("\0") {
            return WorkflowFile(name: name, text: text)
        }
        return WorkflowFile(name: name, unsupportedReason: "Binary file \(name) was not inlined.")
    }
}

public struct WorkflowInputs: Sendable, Equatable {
    public var selection: String?
    public var clipboard: String?
    public var files: [WorkflowFile]

    public init(selection: String? = nil, clipboard: String? = nil, files: [WorkflowFile] = []) {
        self.selection = selection
        self.clipboard = clipboard
        self.files = files
    }
}

public enum WorkflowError: Error, Sendable, Equatable {
    case missingSelection
    case missingClipboard
    case missingFiles
    case emptyResolvedPrompt
}

public struct ResolvedWorkflow: Sendable, Equatable {
    public var prompt: String
    public var model: ModelRef
    public var systemPrompt: String?
    public var agentID: UUID?

    public init(prompt: String, model: ModelRef, systemPrompt: String?, agentID: UUID?) {
        self.prompt = prompt
        self.model = model
        self.systemPrompt = systemPrompt
        self.agentID = agentID
    }
}

public enum WorkflowEngine {
    public static func resolve(
        workflow: Workflow,
        prompt: SavedPrompt?,
        agent: Agent?,
        inputs: WorkflowInputs,
        fallbackModel: ModelRef
    ) throws -> ResolvedWorkflow {
        if workflow.sources.contains(.selection) {
            let selection = inputs.selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if selection.isEmpty { throw WorkflowError.missingSelection }
        }
        if workflow.sources.contains(.clipboard) {
            let clipboard = inputs.clipboard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if clipboard.isEmpty { throw WorkflowError.missingClipboard }
        }
        if workflow.sources.contains(.files) && inputs.files.isEmpty {
            throw WorkflowError.missingFiles
        }
        let template = workflow.template.isEmpty ? (prompt?.body ?? "") : workflow.template
        var resolved = template
        let selection = inputs.selection ?? ""
        let clipboard = inputs.clipboard ?? ""
        let files = renderFiles(inputs.files)
        resolved = resolved.replacingOccurrences(of: "{{selection}}", with: selection)
        resolved = resolved.replacingOccurrences(of: "{{clipboard}}", with: clipboard)
        resolved = resolved.replacingOccurrences(of: "{{files}}", with: files)
        resolved = resolved.replacingOccurrences(of: "{{input}}", with: primaryInput(workflow: workflow, inputs: inputs, files: files))
        resolved = resolved.replacingOccurrences(of: "{{filename}}", with: inputs.files.first?.name ?? "")
        if !template.contains("{{selection}}") && workflow.sources.contains(.selection) {
            resolved += "\n\nSelection:\n\(selection)"
        }
        if !template.contains("{{clipboard}}") && workflow.sources.contains(.clipboard) {
            resolved += "\n\nClipboard:\n\(clipboard)"
        }
        if !template.contains("{{files}}") && workflow.sources.contains(.files) {
            resolved += "\n\nFiles:\n\(files)"
        }
        let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw WorkflowError.emptyResolvedPrompt }
        return ResolvedWorkflow(
            prompt: trimmed,
            model: workflow.model ?? agent?.model ?? fallbackModel,
            systemPrompt: agent?.systemPrompt,
            agentID: agent?.id ?? workflow.agentID
        )
    }

    private static func renderFiles(_ files: [WorkflowFile]) -> String {
        files.map { file in
            if let text = file.text {
                return "\(file.name):\n\(text)"
            }
            return "\(file.name): \(file.unsupportedReason ?? "Unavailable")"
        }.joined(separator: "\n\n")
    }

    private static func primaryInput(workflow: Workflow, inputs: WorkflowInputs, files: String) -> String {
        if workflow.sources.contains(.selection), let selection = inputs.selection, !selection.isEmpty {
            return selection
        }
        if workflow.sources.contains(.clipboard), let clipboard = inputs.clipboard, !clipboard.isEmpty {
            return clipboard
        }
        return files
    }
}

public struct InstantChatDraft: Sendable, Equatable {
    public var text: String
    public var files: [WorkflowFile]
    public var agent: Agent?
    public var model: ModelRef
    public var enabledToolNames: [String]
    public var allowedTools: [ToolDefinition]

    public init(
        text: String,
        files: [WorkflowFile] = [],
        agent: Agent? = nil,
        model: ModelRef,
        enabledToolNames: [String] = [],
        allowedTools: [ToolDefinition] = []
    ) {
        self.text = text
        self.files = files
        self.agent = agent
        self.model = model
        self.enabledToolNames = enabledToolNames
        self.allowedTools = allowedTools
    }

    public func makeRequest() -> ChatRequest {
        let fileBlock = files.map { file in
            if let text = file.text { return "\(file.name):\n\(text)" }
            return "\(file.name): \(file.unsupportedReason ?? "Unavailable")"
        }.joined(separator: "\n\n")
        var userText = text
        if !fileBlock.isEmpty {
            userText += "\n\n" + fileBlock
        }
        var messages: [ProviderMessage] = []
        if let system = agent?.systemPrompt, !system.isEmpty {
            messages.append(ProviderMessage(role: .system, text: system))
        }
        messages.append(ProviderMessage(role: .user, text: userText))
        let allowed = Set(enabledToolNames)
        let tools = allowedTools.filter { allowed.contains($0.name) }
        return ChatRequest(
            model: model,
            messages: messages,
            temperature: agent?.temperature,
            tools: tools,
            stream: true
        )
    }
}

public enum DictationPhase: String, Sendable, Equatable {
    case idle
    case listening
    case transcribing
    case delivering
    case failed
}

public struct DictationState: Sendable, Equatable {
    public var phase: DictationPhase
    public var transcript: String
    public var targetBundleID: String?
    public var error: String?

    public init(
        phase: DictationPhase = .idle,
        transcript: String = "",
        targetBundleID: String? = nil,
        error: String? = nil
    ) {
        self.phase = phase
        self.transcript = transcript
        self.targetBundleID = targetBundleID
        self.error = error
    }
}

public enum DictationEvent: Sendable, Equatable {
    case start(targetBundleID: String)
    case partial(String)
    case finish
    case deliver
    case fail(String)
    case reset
}

public enum DictationReducer {
    public static func reduce(_ state: DictationState, _ event: DictationEvent) -> DictationState {
        var state = state
        switch event {
        case .start(let bundleID):
            state.phase = .listening
            state.transcript = ""
            state.targetBundleID = bundleID
            state.error = nil
        case .partial(let text):
            guard state.phase == .listening || state.phase == .transcribing else { return state }
            state.transcript = text
        case .finish:
            guard state.phase == .listening else { return state }
            state.phase = .transcribing
        case .deliver:
            guard state.phase == .transcribing || state.phase == .listening else { return state }
            let transcript = state.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if transcript.isEmpty || state.targetBundleID == nil {
                state.phase = .failed
                state.error = "Dictation did not produce text to return."
            } else {
                state.phase = .delivering
                state.transcript = transcript
            }
        case .fail(let message):
            state.phase = .failed
            state.error = message
        case .reset:
            return DictationState()
        }
        return state
    }
}

public struct DictationDeliveryPlan: Sendable, Equatable {
    public var targetBundleID: String
    public var text: String
    public var restoresPreviousClipboard: Bool

    public init(targetBundleID: String, text: String, restoresPreviousClipboard: Bool = true) {
        self.targetBundleID = targetBundleID
        self.text = text
        self.restoresPreviousClipboard = restoresPreviousClipboard
    }
}

public enum DictationPlanner {
    public static func plan(state: DictationState) -> DictationDeliveryPlan? {
        guard state.phase == .delivering,
              let bundleID = state.targetBundleID,
              !state.transcript.isEmpty else { return nil }
        return DictationDeliveryPlan(targetBundleID: bundleID, text: state.transcript)
    }
}

public protocol SecretStore: Sendable {
    func save(account: String, secret: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func save(account: String, secret: String) throws {
        lock.lock()
        values[account] = secret
        lock.unlock()
    }

    public func load(account: String) throws -> String? {
        lock.lock()
        let value = values[account]
        lock.unlock()
        return value
    }

    public func delete(account: String) throws {
        lock.lock()
        values[account] = nil
        lock.unlock()
    }
}

public enum CredentialAccount {
    public static let openAI = "openai"
    public static let anthropic = "anthropic"
    public static let gemini = "gemini"
    public static let ollama = "ollama"

    public static func credentials(from store: any SecretStore, ollamaBaseURL: URL) throws -> ProviderCredentials {
        ProviderCredentials(
            openAIKey: try store.load(account: openAI),
            anthropicKey: try store.load(account: anthropic),
            geminiKey: try store.load(account: gemini),
            ollamaBaseURL: ollamaBaseURL
        )
    }
}
