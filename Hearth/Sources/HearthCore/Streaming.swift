import Foundation

public enum ProviderFailure: Error, Sendable, Equatable {
    case rateLimited(retryAfterSeconds: Double?, message: String)
    case server(status: Int, message: String)
    case unauthorized(message: String)
    case network(message: String)
    case malformed(message: String)
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .network, .malformed, .cancelled:
            return true
        case .unauthorized:
            return false
        case .server(let status, _):
            return status >= 500 || status == 408 || status == 429
        }
    }

    public var displayMessage: String {
        switch self {
        case .rateLimited(let retryAfter, let message):
            if let retryAfter {
                return "\(message) Retry after \(Int(retryAfter.rounded(.up)))s."
            }
            return message
        case .server(_, let message), .unauthorized(let message), .network(let message), .malformed(let message):
            return message
        case .cancelled:
            return "Cancelled."
        }
    }
}

public enum StreamPhase: String, Sendable, Equatable {
    case idle
    case streaming
    case completed
    case cancelled
    case failed
    case interrupted
}

public enum StreamEvent: Sendable, Equatable {
    case started
    case text(String)
    case reasoning(String)
    case citation(Citation)
    case toolCallDelta(id: String, name: String?, argumentsDelta: String)
    case toolResult(ToolResult)
    case completed(finishReason: String?)
    case cancelled
    case failed(ProviderFailure)
    case interrupted
}

public struct StreamSnapshot: Sendable, Equatable {
    public var phase: StreamPhase
    public var text: String
    public var reasoning: String
    public var citations: [Citation]
    public var toolCalls: [ToolCallDraft]
    public var toolResults: [ToolResult]
    public var failure: ProviderFailure?
    public var finishReason: String?

    public init(
        phase: StreamPhase = .idle,
        text: String = "",
        reasoning: String = "",
        citations: [Citation] = [],
        toolCalls: [ToolCallDraft] = [],
        toolResults: [ToolResult] = [],
        failure: ProviderFailure? = nil,
        finishReason: String? = nil
    ) {
        self.phase = phase
        self.text = text
        self.reasoning = reasoning
        self.citations = citations
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.failure = failure
        self.finishReason = finishReason
    }

    public var hasContent: Bool {
        !text.isEmpty || !reasoning.isEmpty || !toolCalls.isEmpty || !toolResults.isEmpty || !citations.isEmpty
    }
}

public enum StreamStatusMap {
    public static func messageStatus(phase: StreamPhase, hasContent: Bool) -> MessageStatus {
        switch phase {
        case .idle, .streaming:
            return .streaming
        case .completed:
            return .complete
        case .cancelled:
            return hasContent ? .partial : .cancelled
        case .failed:
            return hasContent ? .partial : .failed
        case .interrupted:
            return .interrupted
        }
    }

    public static func retryable(phase: StreamPhase, failure: ProviderFailure?) -> Bool {
        switch phase {
        case .completed, .idle:
            return false
        case .streaming:
            return false
        case .cancelled, .interrupted:
            return true
        case .failed:
            return failure?.isRetryable ?? true
        }
    }
}

public enum StreamingReducer {
    public static func reduce(_ snapshot: StreamSnapshot, _ event: StreamEvent) -> StreamSnapshot {
        var snapshot = snapshot
        switch event {
        case .started:
            guard snapshot.phase == .idle else { return snapshot }
            snapshot.phase = .streaming
        case .text(let chunk):
            guard continueStreaming(&snapshot) else { return snapshot }
            snapshot.text += chunk
        case .reasoning(let chunk):
            guard continueStreaming(&snapshot) else { return snapshot }
            snapshot.reasoning += chunk
        case .citation(let citation):
            guard continueStreaming(&snapshot) else { return snapshot }
            snapshot.citations.append(citation)
        case .toolCallDelta(let id, let name, let argumentsDelta):
            guard continueStreaming(&snapshot) else { return snapshot }
            if let index = snapshot.toolCalls.firstIndex(where: { $0.id == id }) {
                if let name, !name.isEmpty {
                    snapshot.toolCalls[index].name = name
                }
                snapshot.toolCalls[index].arguments += argumentsDelta
            } else {
                snapshot.toolCalls.append(
                    ToolCallDraft(id: id, name: name ?? "", arguments: argumentsDelta)
                )
            }
        case .toolResult(let result):
            guard continueStreaming(&snapshot) else { return snapshot }
            snapshot.toolResults.append(result)
        case .completed(let reason):
            guard snapshot.phase == .idle || snapshot.phase == .streaming else { return snapshot }
            snapshot.phase = .completed
            snapshot.finishReason = reason
        case .cancelled:
            guard snapshot.phase == .idle || snapshot.phase == .streaming else { return snapshot }
            snapshot.phase = .cancelled
        case .failed(let failure):
            guard snapshot.phase == .idle || snapshot.phase == .streaming else { return snapshot }
            snapshot.phase = .failed
            snapshot.failure = failure
        case .interrupted:
            guard snapshot.phase == .idle || snapshot.phase == .streaming else { return snapshot }
            snapshot.phase = .interrupted
        }
        return snapshot
    }

    private static func continueStreaming(_ snapshot: inout StreamSnapshot) -> Bool {
        if snapshot.phase == .idle {
            snapshot.phase = .streaming
        }
        return snapshot.phase == .streaming
    }
}

public struct StreamCoalescer: Equatable, Sendable {
    public var intervalMS: Double
    public private(set) var pending: String
    private var lastEmitMS: Double?

    public init(intervalMS: Double = 33) {
        self.intervalMS = intervalMS
        self.pending = ""
        self.lastEmitMS = nil
    }

    public mutating func push(delta: String, nowMS: Double) -> String? {
        pending += delta
        if let lastEmitMS, nowMS - lastEmitMS < intervalMS {
            return nil
        }
        return flush(nowMS: nowMS)
    }

    public mutating func flush(nowMS: Double = 0) -> String? {
        guard !pending.isEmpty else { return nil }
        let value = pending
        pending = ""
        lastEmitMS = nowMS
        return value
    }
}

public enum TranscriptWindow {
    public static func visibleRange(total: Int, anchor: Int, viewport: Int, overscan: Int) -> Range<Int> {
        guard total > 0, viewport > 0 else { return 0..<0 }
        let clampedAnchor = min(max(0, anchor), total - 1)
        let start = max(0, clampedAnchor - overscan)
        let end = min(total, start + viewport + (overscan * 2))
        return start..<end
    }
}

public struct ComposerEditor: Equatable, Sendable {
    public var text: String

    public init(text: String = "") {
        self.text = text
    }

    public mutating func insert(_ value: String) {
        text += value
    }

    public mutating func clear() {
        text = ""
    }
}

public enum RepositoryError: Error, Sendable, Equatable {
    case notFound(String)
    case invalidFork
    case nothingToRetry
    case nothingToRegenerate
    case busyStreaming
    case corruptStore(String)
}

public struct TurnChange: Sendable, Equatable {
    public var upsertMessages: [Message]
    public var deleteMessageIDs: [UUID]
    public var contextMessages: [Message]
    public var assistantMessage: Message
    public var chat: Chat

    public init(
        upsertMessages: [Message],
        deleteMessageIDs: [UUID],
        contextMessages: [Message],
        assistantMessage: Message,
        chat: Chat
    ) {
        self.upsertMessages = upsertMessages
        self.deleteMessageIDs = deleteMessageIDs
        self.contextMessages = contextMessages
        self.assistantMessage = assistantMessage
        self.chat = chat
    }
}

public enum TurnPreparation {
    public static func beginSend(
        snapshot: WorkspaceSnapshot,
        chatID: UUID,
        userText: String,
        attachmentIDs: [UUID],
        now: Date
    ) throws -> TurnChange {
        guard var chat = snapshot.chats.first(where: { $0.id == chatID }) else {
            throw RepositoryError.notFound("chat")
        }
        let existing = snapshot.messages
            .filter { $0.chatID == chatID }
            .sorted { $0.ordinal < $1.ordinal }
        if existing.last?.status == .streaming {
            throw RepositoryError.busyStreaming
        }
        let nextOrdinal = (existing.last?.ordinal ?? -1) + 1
        let user = Message(
            id: UUID(),
            chatID: chatID,
            role: .user,
            text: userText,
            status: .complete,
            attachmentIDs: attachmentIDs,
            createdAt: now,
            ordinal: nextOrdinal
        )
        let assistant = Message(
            id: UUID(),
            chatID: chatID,
            role: .assistant,
            text: "",
            status: .streaming,
            createdAt: now,
            ordinal: nextOrdinal + 1
        )
        if chat.title == "New chat" {
            chat.title = ChatTitle.fromUserText(userText)
        }
        chat.updatedAt = now
        return TurnChange(
            upsertMessages: [user, assistant],
            deleteMessageIDs: [],
            contextMessages: existing + [user],
            assistantMessage: assistant,
            chat: chat
        )
    }

    public static func retry(snapshot: WorkspaceSnapshot, chatID: UUID, now: Date) throws -> TurnChange {
        guard var chat = snapshot.chats.first(where: { $0.id == chatID }) else {
            throw RepositoryError.notFound("chat")
        }
        let existing = snapshot.messages
            .filter { $0.chatID == chatID }
            .sorted { $0.ordinal < $1.ordinal }
        guard let last = existing.last else {
            throw RepositoryError.nothingToRetry
        }
        if last.status == .streaming {
            throw RepositoryError.busyStreaming
        }
        chat.updatedAt = now
        if last.role == .assistant {
            guard last.status == .failed || last.status == .partial || last.status == .cancelled || last.status == .interrupted else {
                throw RepositoryError.nothingToRetry
            }
            var reset = last
            reset.text = ""
            reset.reasoning = ""
            reset.citations = []
            reset.toolCalls = []
            reset.toolResults = []
            reset.status = .streaming
            reset.errorMessage = nil
            reset.retryable = false
            let context = Array(existing.dropLast())
            return TurnChange(
                upsertMessages: [reset],
                deleteMessageIDs: [],
                contextMessages: context,
                assistantMessage: reset,
                chat: chat
            )
        }
        let assistant = Message(
            id: UUID(),
            chatID: chatID,
            role: .assistant,
            text: "",
            status: .streaming,
            createdAt: now,
            ordinal: last.ordinal + 1
        )
        return TurnChange(
            upsertMessages: [assistant],
            deleteMessageIDs: [],
            contextMessages: existing,
            assistantMessage: assistant,
            chat: chat
        )
    }

    public static func regenerate(snapshot: WorkspaceSnapshot, chatID: UUID, now: Date) throws -> TurnChange {
        guard var chat = snapshot.chats.first(where: { $0.id == chatID }) else {
            throw RepositoryError.notFound("chat")
        }
        let existing = snapshot.messages
            .filter { $0.chatID == chatID }
            .sorted { $0.ordinal < $1.ordinal }
        guard let last = existing.last, last.role == .assistant else {
            throw RepositoryError.nothingToRegenerate
        }
        if last.status == .streaming {
            throw RepositoryError.busyStreaming
        }
        let context = Array(existing.dropLast())
        let assistant = Message(
            id: UUID(),
            chatID: chatID,
            role: .assistant,
            text: "",
            status: .streaming,
            createdAt: now,
            ordinal: last.ordinal
        )
        chat.updatedAt = now
        return TurnChange(
            upsertMessages: [assistant],
            deleteMessageIDs: [last.id],
            contextMessages: context,
            assistantMessage: assistant,
            chat: chat
        )
    }
}

public enum Recovery {
    public static func interruptStreaming(_ snapshot: WorkspaceSnapshot) -> (WorkspaceSnapshot, [UUID]) {
        var snapshot = snapshot
        var ids: [UUID] = []
        for index in snapshot.messages.indices where snapshot.messages[index].status == .streaming {
            snapshot.messages[index].status = .interrupted
            snapshot.messages[index].retryable = true
            if snapshot.messages[index].errorMessage == nil {
                snapshot.messages[index].errorMessage = "Stream interrupted before completion. The partial response was kept."
            }
            ids.append(snapshot.messages[index].id)
        }
        return (snapshot, ids)
    }
}

public func apply(_ snapshot: StreamSnapshot, to message: Message) -> Message {
    var message = message
    message.text = snapshot.text
    message.reasoning = snapshot.reasoning
    message.citations = snapshot.citations
    message.toolCalls = snapshot.toolCalls
    message.toolResults = snapshot.toolResults
    message.status = StreamStatusMap.messageStatus(phase: snapshot.phase, hasContent: snapshot.hasContent)
    message.retryable = StreamStatusMap.retryable(phase: snapshot.phase, failure: snapshot.failure)
    message.errorMessage = snapshot.failure?.displayMessage
    if snapshot.phase == .interrupted && message.errorMessage == nil {
        message.errorMessage = "Stream ended before the provider finished. The partial response was kept."
    }
    if snapshot.phase == .cancelled && snapshot.hasContent && message.errorMessage == nil {
        message.errorMessage = "Cancelled. The partial response was kept."
    }
    return message
}
