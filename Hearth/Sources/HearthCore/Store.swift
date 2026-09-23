import Foundation

public enum SnapshotCodec {
    public static func encode(_ snapshot: WorkspaceSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> WorkspaceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceSnapshot.self, from: data)
    }
}

public enum StoreLayout {
    public static func storeFile(_ directory: URL) -> URL {
        directory.appendingPathComponent("store.json")
    }

    public static func storeTemporaryFile(_ directory: URL) -> URL {
        directory.appendingPathComponent("store.json.tmp")
    }

    public static func attachmentsDirectory(_ directory: URL) -> URL {
        directory.appendingPathComponent("attachments", isDirectory: true)
    }

    public static func attachmentURL(_ directory: URL, id: UUID) -> URL {
        attachmentsDirectory(directory).appendingPathComponent(id.uuidString)
    }

    public static func manifestFile(_ directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }
}

public struct WorkspaceDatabase: Sendable, Equatable {
    public private(set) var snapshot: WorkspaceSnapshot

    public init(snapshot: WorkspaceSnapshot = .empty) {
        self.snapshot = snapshot
    }

    public mutating func upsertProject(_ project: Project) {
        upsert(&snapshot.projects, project)
    }

    public mutating func upsertChat(_ chat: Chat) {
        upsert(&snapshot.chats, chat)
    }

    public mutating func upsertMessage(_ message: Message) {
        upsert(&snapshot.messages, message)
    }

    public mutating func deleteMessages(_ ids: [UUID]) {
        let doomed = Set(ids)
        snapshot.messages.removeAll { doomed.contains($0.id) }
    }

    public mutating func upsertAttachment(_ attachment: Attachment) {
        upsert(&snapshot.attachments, attachment)
    }

    public mutating func upsertAgent(_ agent: Agent) {
        upsert(&snapshot.agents, agent)
    }

    public mutating func upsertPrompt(_ prompt: SavedPrompt) {
        upsert(&snapshot.prompts, prompt)
    }

    public mutating func upsertWorkflow(_ workflow: Workflow) {
        upsert(&snapshot.workflows, workflow)
    }

    public mutating func upsertMCPServer(_ server: MCPServer) {
        upsert(&snapshot.mcpServers, server)
    }

    public mutating func apply(_ change: TurnChange) {
        deleteMessages(change.deleteMessageIDs)
        for message in change.upsertMessages {
            upsertMessage(message)
        }
        upsertChat(change.chat)
    }

    public mutating func recoverInterruptedStreams() -> [UUID] {
        let (updated, ids) = Recovery.interruptStreaming(snapshot)
        snapshot = updated
        return ids
    }

    public mutating func forkChat(_ chatID: UUID, through messageID: UUID, now: Date) throws -> ForkResult {
        guard let chat = snapshot.chats.first(where: { $0.id == chatID }) else {
            throw RepositoryError.notFound("chat")
        }
        let messages = self.messages(for: chatID)
        guard let pivot = messages.first(where: { $0.id == messageID }) else {
            throw RepositoryError.invalidFork
        }
        let copied = messages.filter { $0.ordinal <= pivot.ordinal }
        let newChatID = UUID()
        var attachmentCopies: [AttachmentCopy] = []
        var newMessages: [Message] = []
        for message in copied {
            var clone = message
            clone.id = UUID()
            clone.chatID = newChatID
            var newAttachmentIDs: [UUID] = []
            for attachmentID in message.attachmentIDs {
                guard let attachment = snapshot.attachments.first(where: { $0.id == attachmentID }) else {
                    continue
                }
                let copyID = UUID()
                var copiedAttachment = attachment
                copiedAttachment.id = copyID
                copiedAttachment.relativePath = "attachments/\(copyID.uuidString)"
                upsertAttachment(copiedAttachment)
                attachmentCopies.append(
                    AttachmentCopy(
                        from: attachment.id,
                        to: copyID,
                        filename: attachment.filename,
                        mimeType: attachment.mimeType,
                        byteCount: attachment.byteCount
                    )
                )
                newAttachmentIDs.append(copyID)
            }
            clone.attachmentIDs = newAttachmentIDs
            newMessages.append(clone)
        }
        let forked = Chat(
            id: newChatID,
            projectID: chat.projectID,
            title: chat.title + " fork",
            agentID: chat.agentID,
            model: chat.model,
            createdAt: now,
            updatedAt: now,
            forkedFromChatID: chat.id,
            forkedFromMessageID: messageID
        )
        upsertChat(forked)
        for message in newMessages {
            upsertMessage(message)
        }
        return ForkResult(chat: forked, messages: newMessages, attachmentCopies: attachmentCopies)
    }

    public func messages(for chatID: UUID) -> [Message] {
        snapshot.messages
            .filter { $0.chatID == chatID }
            .sorted { $0.ordinal < $1.ordinal }
    }

    public func search(_ query: String, limit: Int = 50) -> [SearchHit] {
        FullTextIndex(messages: snapshot.messages).search(query, limit: limit)
    }

    public mutating func ensureFirstRun(now: Date) -> Bool {
        guard snapshot.projects.isEmpty else { return false }
        snapshot = FirstRun.bootstrap(now: now)
        return true
    }

    private func upsert<T: Identifiable>(_ items: inout [T], _ item: T) where T.ID: Equatable {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }
}

public struct AttachmentCopy: Sendable, Equatable {
    public var from: UUID
    public var to: UUID
    public var filename: String
    public var mimeType: String
    public var byteCount: Int

    public init(from: UUID, to: UUID, filename: String, mimeType: String, byteCount: Int) {
        self.from = from
        self.to = to
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

public struct ForkResult: Sendable, Equatable {
    public var chat: Chat
    public var messages: [Message]
    public var attachmentCopies: [AttachmentCopy]

    public init(chat: Chat, messages: [Message], attachmentCopies: [AttachmentCopy]) {
        self.chat = chat
        self.messages = messages
        self.attachmentCopies = attachmentCopies
    }
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var messageID: UUID
    public var chatID: UUID
    public var snippet: String
    public var score: Int

    public var id: UUID { messageID }

    public init(messageID: UUID, chatID: UUID, snippet: String, score: Int) {
        self.messageID = messageID
        self.chatID = chatID
        self.snippet = snippet
        self.score = score
    }
}

public struct FullTextIndex: Sendable, Equatable {
    private var postings: [String: [UUID]]
    private var messages: [UUID: Message]

    public init(messages: [Message]) {
        var postings: [String: [UUID]] = [:]
        var lookup: [UUID: Message] = [:]
        for message in messages {
            lookup[message.id] = message
            var seen = Set<String>()
            for token in FullTextIndex.tokens(message.text + " " + message.reasoning) where seen.insert(token).inserted {
                postings[token, default: []].append(message.id)
            }
        }
        self.postings = postings
        self.messages = lookup
    }

    public func search(_ query: String, limit: Int = 50) -> [SearchHit] {
        let terms = FullTextIndex.tokens(query)
        guard !terms.isEmpty else { return [] }
        var scores: [UUID: Int] = [:]
        for term in terms {
            for id in postings[term] ?? [] {
                scores[id, default: 0] += 1
            }
        }
        let required = terms.count
        let ranked = scores
            .filter { $0.value == required }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let left = messages[lhs.key]?.createdAt ?? .distantPast
                let right = messages[rhs.key]?.createdAt ?? .distantPast
                return left > right
            }
        return ranked.prefix(limit).compactMap { entry in
            guard let message = messages[entry.key] else { return nil }
            return SearchHit(
                messageID: message.id,
                chatID: message.chatID,
                snippet: FullTextIndex.snippet(in: message.text, terms: terms),
                score: entry.value
            )
        }
    }

    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func snippet(in text: String, terms: [String]) -> String {
        let lower = text.lowercased()
        let match = terms.compactMap { term -> Range<String.Index>? in
            lower.range(of: term)
        }.first
        guard let match else {
            return String(text.prefix(80))
        }
        let start = text.index(match.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start != text.startIndex { snippet = "…" + snippet }
        if end != text.endIndex { snippet += "…" }
        return snippet
    }
}

public struct ExportedAttachment: Codable, Sendable, Equatable {
    public var attachment: Attachment
    public var base64: String

    public init(attachment: Attachment, base64: String) {
        self.attachment = attachment
        self.base64 = base64
    }
}

public struct ChatExport: Codable, Sendable, Equatable {
    public static let formatID = "hearth.chat.v1"

    public var format: String
    public var chat: Chat
    public var project: Project?
    public var messages: [Message]
    public var attachments: [ExportedAttachment]

    public init(format: String = ChatExport.formatID, chat: Chat, project: Project?, messages: [Message], attachments: [ExportedAttachment]) {
        self.format = format
        self.chat = chat
        self.project = project
        self.messages = messages
        self.attachments = attachments
    }
}

public struct BackupManifest: Codable, Sendable, Equatable {
    public static let formatID = "hearth.backup.v1"

    public var format: String
    public var createdAt: Date

    public init(format: String = BackupManifest.formatID, createdAt: Date) {
        self.format = format
        self.createdAt = createdAt
    }
}

public protocol ChatRepository: Sendable {
    func snapshot() async throws -> WorkspaceSnapshot
    func saveProject(_ project: Project) async throws
    func saveChat(_ chat: Chat) async throws
    func saveMessage(_ message: Message) async throws
    func deleteMessages(_ ids: [UUID]) async throws
    func saveAttachment(_ attachment: Attachment, data: Data) async throws
    func dataForAttachment(_ id: UUID) async throws -> Data
    func saveAgent(_ agent: Agent) async throws
    func savePrompt(_ prompt: SavedPrompt) async throws
    func saveWorkflow(_ workflow: Workflow) async throws
    func saveMCPServer(_ server: MCPServer) async throws
    func apply(_ change: TurnChange) async throws
    func recoverInterruptedStreams() async throws -> [UUID]
    func forkChat(_ chatID: UUID, through messageID: UUID, now: Date) async throws -> Chat
    func search(_ query: String, limit: Int) async throws -> [SearchHit]
    func exportChat(_ chatID: UUID) async throws -> Data
    func importOwnExport(_ data: Data) async throws -> Chat
    func backup(to directory: URL, now: Date) async throws
    func restore(from directory: URL) async throws
    func ensureFirstRun(now: Date) async throws -> Bool
}

public actor SnapshotChatStore: ChatRepository {
    public let directory: URL
    private var database: WorkspaceDatabase

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: StoreLayout.attachmentsDirectory(directory), withIntermediateDirectories: true)
        let snapshot = try SnapshotChatStore.readSnapshot(in: directory)
        self.database = WorkspaceDatabase(snapshot: snapshot)
    }

    public func snapshot() -> WorkspaceSnapshot {
        database.snapshot
    }

    public func saveProject(_ project: Project) throws {
        database.upsertProject(project)
        try persist()
    }

    public func saveChat(_ chat: Chat) throws {
        database.upsertChat(chat)
        try persist()
    }

    public func saveMessage(_ message: Message) throws {
        database.upsertMessage(message)
        try persist()
    }

    public func deleteMessages(_ ids: [UUID]) throws {
        database.deleteMessages(ids)
        try persist()
    }

    public func saveAttachment(_ attachment: Attachment, data: Data) throws {
        var stored = attachment
        stored.byteCount = data.count
        stored.relativePath = "attachments/\(stored.id.uuidString)"
        let url = StoreLayout.attachmentURL(directory, id: stored.id)
        try data.write(to: url, options: .atomic)
        database.upsertAttachment(stored)
        try persist()
    }

    public func dataForAttachment(_ id: UUID) throws -> Data {
        guard database.snapshot.attachments.contains(where: { $0.id == id }) else {
            throw RepositoryError.notFound("attachment")
        }
        let url = StoreLayout.attachmentURL(directory, id: id)
        return try Data(contentsOf: url)
    }

    public func saveAgent(_ agent: Agent) throws {
        database.upsertAgent(agent)
        try persist()
    }

    public func savePrompt(_ prompt: SavedPrompt) throws {
        database.upsertPrompt(prompt)
        try persist()
    }

    public func saveWorkflow(_ workflow: Workflow) throws {
        database.upsertWorkflow(workflow)
        try persist()
    }

    public func saveMCPServer(_ server: MCPServer) throws {
        database.upsertMCPServer(server)
        try persist()
    }

    public func apply(_ change: TurnChange) throws {
        database.apply(change)
        try persist()
    }

    public func recoverInterruptedStreams() throws -> [UUID] {
        let ids = database.recoverInterruptedStreams()
        if !ids.isEmpty {
            try persist()
        }
        return ids
    }

    public func forkChat(_ chatID: UUID, through messageID: UUID, now: Date) throws -> Chat {
        let result = try database.forkChat(chatID, through: messageID, now: now)
        for copy in result.attachmentCopies {
            let source = StoreLayout.attachmentURL(directory, id: copy.from)
            let destination = StoreLayout.attachmentURL(directory, id: copy.to)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
        try persist()
        return result.chat
    }

    public func search(_ query: String, limit: Int) -> [SearchHit] {
        database.search(query, limit: limit)
    }

    public func exportChat(_ chatID: UUID) throws -> Data {
        guard let chat = database.snapshot.chats.first(where: { $0.id == chatID }) else {
            throw RepositoryError.notFound("chat")
        }
        let project = database.snapshot.projects.first { $0.id == chat.projectID }
        let messages = database.messages(for: chatID)
        let attachmentIDs = Set(messages.flatMap(\.attachmentIDs))
        let attachments = try database.snapshot.attachments.filter { attachmentIDs.contains($0.id) }.map { attachment in
            let bytes = try Data(contentsOf: StoreLayout.attachmentURL(directory, id: attachment.id))
            return ExportedAttachment(attachment: attachment, base64: bytes.base64EncodedString())
        }
        let export = ChatExport(chat: chat, project: project, messages: messages, attachments: attachments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    public func importOwnExport(_ data: Data) throws -> Chat {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ChatExport.self, from: data)
        guard export.format == ChatExport.formatID else {
            throw RepositoryError.corruptStore("Unsupported export format")
        }
        if let project = export.project, !database.snapshot.projects.contains(where: { $0.id == project.id }) {
            database.upsertProject(project)
        }
        database.upsertChat(export.chat)
        for message in export.messages {
            database.upsertMessage(message)
        }
        for item in export.attachments {
            guard let bytes = Data(base64Encoded: item.base64) else {
                throw RepositoryError.corruptStore("Attachment bytes were not valid")
            }
            try dataWrite(bytes, id: item.attachment.id)
            database.upsertAttachment(item.attachment)
        }
        try persist()
        return export.chat
    }

    public func backup(to directory: URL, now: Date) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: StoreLayout.attachmentsDirectory(directory), withIntermediateDirectories: true)
        let manifest = BackupManifest(createdAt: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: StoreLayout.manifestFile(directory), options: .atomic)
        try SnapshotCodec.encode(database.snapshot).write(to: StoreLayout.storeFile(directory), options: .atomic)
        for attachment in database.snapshot.attachments {
            let source = StoreLayout.attachmentURL(self.directory, id: attachment.id)
            let destination = StoreLayout.attachmentURL(directory, id: attachment.id)
            if fileManager.fileExists(atPath: source.path) {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }

    public func restore(from directory: URL) throws {
        let manifestData = try Data(contentsOf: StoreLayout.manifestFile(directory))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: manifestData)
        guard manifest.format == BackupManifest.formatID else {
            throw RepositoryError.corruptStore("Unsupported backup format")
        }
        let snapshot = try SnapshotCodec.decode(try Data(contentsOf: StoreLayout.storeFile(directory)))
        let fileManager = FileManager.default
        let attachments = StoreLayout.attachmentsDirectory(self.directory)
        if fileManager.fileExists(atPath: attachments.path) {
            try fileManager.removeItem(at: attachments)
        }
        try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
        for attachment in snapshot.attachments {
            let source = StoreLayout.attachmentURL(directory, id: attachment.id)
            let destination = StoreLayout.attachmentURL(self.directory, id: attachment.id)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }
        database = WorkspaceDatabase(snapshot: snapshot)
        try persist()
    }

    public func ensureFirstRun(now: Date) throws -> Bool {
        let created = database.ensureFirstRun(now: now)
        if created {
            try persist()
        }
        return created
    }

    private func dataWrite(_ data: Data, id: UUID) throws {
        try data.write(to: StoreLayout.attachmentURL(directory, id: id), options: .atomic)
    }

    private func persist() throws {
        let data = try SnapshotCodec.encode(database.snapshot)
        let temporary = StoreLayout.storeTemporaryFile(directory)
        let primary = StoreLayout.storeFile(directory)
        try data.write(to: temporary, options: .atomic)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: primary.path) {
            try fileManager.removeItem(at: primary)
        }
        try fileManager.moveItem(at: temporary, to: primary)
    }

    private static func readSnapshot(in directory: URL) throws -> WorkspaceSnapshot {
        let fileManager = FileManager.default
        let primary = StoreLayout.storeFile(directory)
        let temporary = StoreLayout.storeTemporaryFile(directory)
        let url: URL
        if fileManager.fileExists(atPath: primary.path) {
            url = primary
        } else if fileManager.fileExists(atPath: temporary.path) {
            url = temporary
        } else {
            return .empty
        }
        do {
            return try SnapshotCodec.decode(try Data(contentsOf: url))
        } catch {
            throw RepositoryError.corruptStore("Could not read the local store")
        }
    }
}

extension SnapshotChatStore {
    public func replaceSnapshotForTesting(_ snapshot: WorkspaceSnapshot) throws {
        database = WorkspaceDatabase(snapshot: snapshot)
        try persist()
    }
}
