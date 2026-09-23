#if os(macOS)
import CoreData
import Foundation
import HearthCore

public enum HearthModel {
    public static func make() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let project = entity("Project", [
            attribute("id", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("instructions", .stringAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
        ])
        let chat = entity("Chat", [
            attribute("id", .stringAttributeType),
            attribute("projectID", .stringAttributeType),
            attribute("title", .stringAttributeType),
            attribute("agentID", .stringAttributeType, optional: true),
            attribute("provider", .stringAttributeType),
            attribute("modelName", .stringAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("updatedAt", .dateAttributeType),
            attribute("forkedFromChatID", .stringAttributeType, optional: true),
            attribute("forkedFromMessageID", .stringAttributeType, optional: true),
        ])
        let messageChatID = attribute("chatID", .stringAttributeType)
        let messageStatus = attribute("status", .stringAttributeType)
        let message = entity("Message", [
            attribute("id", .stringAttributeType),
            messageChatID,
            attribute("role", .stringAttributeType),
            attribute("text", .stringAttributeType),
            attribute("reasoning", .stringAttributeType),
            messageStatus,
            attribute("errorMessage", .stringAttributeType, optional: true),
            attribute("retryable", .booleanAttributeType),
            attribute("citationsJSON", .stringAttributeType),
            attribute("toolCallsJSON", .stringAttributeType),
            attribute("toolResultsJSON", .stringAttributeType),
            attribute("attachmentIDsJSON", .stringAttributeType),
            attribute("createdAt", .dateAttributeType),
            attribute("ordinal", .integer64AttributeType),
        ])
        message.indexes = [
            NSFetchIndexDescription(name: "by_chat", elements: [
                NSFetchIndexElementDescription(property: messageChatID, collationType: .binary),
            ]),
            NSFetchIndexDescription(name: "by_status", elements: [
                NSFetchIndexElementDescription(property: messageStatus, collationType: .binary),
            ]),
        ]
        let attachment = entity("Attachment", [
            attribute("id", .stringAttributeType),
            attribute("filename", .stringAttributeType),
            attribute("mimeType", .stringAttributeType),
            attribute("byteCount", .integer64AttributeType),
            attribute("relativePath", .stringAttributeType),
        ])
        let agent = entity("Agent", [
            attribute("id", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("systemPrompt", .stringAttributeType),
            attribute("provider", .stringAttributeType),
            attribute("modelName", .stringAttributeType),
            attribute("temperature", .doubleAttributeType, optional: true),
            attribute("enabledToolNamesJSON", .stringAttributeType),
            attribute("mcpServerIDsJSON", .stringAttributeType),
        ])
        let prompt = entity("Prompt", [
            attribute("id", .stringAttributeType),
            attribute("title", .stringAttributeType),
            attribute("body", .stringAttributeType),
            attribute("createdAt", .dateAttributeType),
        ])
        let workflow = entity("Workflow", [
            attribute("id", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("template", .stringAttributeType),
            attribute("sourcesJSON", .stringAttributeType),
            attribute("agentID", .stringAttributeType, optional: true),
            attribute("provider", .stringAttributeType, optional: true),
            attribute("modelName", .stringAttributeType, optional: true),
        ])
        let server = entity("MCPServer", [
            attribute("id", .stringAttributeType),
            attribute("name", .stringAttributeType),
            attribute("transport", .stringAttributeType),
            attribute("command", .stringAttributeType, optional: true),
            attribute("argumentsJSON", .stringAttributeType),
            attribute("url", .stringAttributeType, optional: true),
            attribute("enabled", .booleanAttributeType),
        ])
        model.entities = [project, chat, message, attachment, agent, prompt, workflow, server]
        return model
    }

    private static func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }

    private static func entity(_ name: String, _ properties: [NSAttributeDescription]) -> NSEntityDescription {
        let entity = NSEntityDescription()
        entity.name = name
        entity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        entity.properties = properties
        return entity
    }
}

public final class CoreDataChatStore: ChatRepository, @unchecked Sendable {
    public let directory: URL
    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    private let lock = NSLock()
    private var database: WorkspaceDatabase
    private let entityNames = ["Project", "Chat", "Message", "Attachment", "Agent", "Prompt", "Workflow", "MCPServer"]

    public init(directory: URL, inMemory: Bool = false) async throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: StoreLayout.attachmentsDirectory(directory), withIntermediateDirectories: true)
        let container = NSPersistentContainer(name: "Hearth", managedObjectModel: HearthModel.make())
        let description = NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
        } else {
            description.type = NSSQLiteStoreType
            description.url = directory.appendingPathComponent("hearth.sqlite")
        }
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        self.container = container
        self.context = context
        self.database = WorkspaceDatabase()
        let loaded = try await loadDatabase()
        self.database = loaded
    }

    public func snapshot() async throws -> WorkspaceSnapshot {
        lock.lock()
        let copy = database.snapshot
        lock.unlock()
        return copy
    }

    public func saveProject(_ project: Project) async throws {
        mutate { $0.upsertProject(project) }
        try await perform { try self.upsert(entity: "Project", id: project.id.uuidString) { self.fill($0, project) } }
    }

    public func saveChat(_ chat: Chat) async throws {
        mutate { $0.upsertChat(chat) }
        try await perform { try self.upsert(entity: "Chat", id: chat.id.uuidString) { self.fill($0, chat) } }
    }

    public func saveMessage(_ message: Message) async throws {
        mutate { $0.upsertMessage(message) }
        try await perform { try self.upsert(entity: "Message", id: message.id.uuidString) { self.fill($0, message) } }
    }

    public func deleteMessages(_ ids: [UUID]) async throws {
        mutate { $0.deleteMessages(ids) }
        try await perform {
            for id in ids {
                if let object = try self.existing(entity: "Message", id: id.uuidString) {
                    self.context.delete(object)
                }
            }
            try self.saveContext()
        }
    }

    public func saveAttachment(_ attachment: Attachment, data: Data) async throws {
        var stored = attachment
        stored.byteCount = data.count
        stored.relativePath = "attachments/\(stored.id.uuidString)"
        try data.write(to: StoreLayout.attachmentURL(directory, id: stored.id), options: .atomic)
        mutate { $0.upsertAttachment(stored) }
        try await perform { try self.upsert(entity: "Attachment", id: stored.id.uuidString) { self.fill($0, stored) } }
    }

    public func dataForAttachment(_ id: UUID) async throws -> Data {
        let known = withDatabase { $0.snapshot.attachments.contains { $0.id == id } }
        guard known else { throw RepositoryError.notFound("attachment") }
        return try Data(contentsOf: StoreLayout.attachmentURL(directory, id: id))
    }

    public func saveAgent(_ agent: Agent) async throws {
        mutate { $0.upsertAgent(agent) }
        try await perform { try self.upsert(entity: "Agent", id: agent.id.uuidString) { self.fill($0, agent) } }
    }

    public func savePrompt(_ prompt: SavedPrompt) async throws {
        mutate { $0.upsertPrompt(prompt) }
        try await perform { try self.upsert(entity: "Prompt", id: prompt.id.uuidString) { self.fill($0, prompt) } }
    }

    public func saveWorkflow(_ workflow: Workflow) async throws {
        mutate { $0.upsertWorkflow(workflow) }
        try await perform { try self.upsert(entity: "Workflow", id: workflow.id.uuidString) { self.fill($0, workflow) } }
    }

    public func saveMCPServer(_ server: MCPServer) async throws {
        mutate { $0.upsertMCPServer(server) }
        try await perform { try self.upsert(entity: "MCPServer", id: server.id.uuidString) { self.fill($0, server) } }
    }

    public func apply(_ change: TurnChange) async throws {
        mutate { $0.apply(change) }
        try await perform {
            for id in change.deleteMessageIDs {
                if let object = try self.existing(entity: "Message", id: id.uuidString) {
                    self.context.delete(object)
                }
            }
            try self.upsert(entity: "Chat", id: change.chat.id.uuidString) { self.fill($0, change.chat) }
            for message in change.upsertMessages {
                try self.upsert(entity: "Message", id: message.id.uuidString) { self.fill($0, message) }
            }
        }
    }

    public func recoverInterruptedStreams() async throws -> [UUID] {
        let ids: [UUID] = mutate { $0.recoverInterruptedStreams() }
        guard !ids.isEmpty else { return [] }
        let messages = withDatabase { database in
            database.snapshot.messages.filter { ids.contains($0.id) }
        }
        try await perform {
            for message in messages {
                try self.upsert(entity: "Message", id: message.id.uuidString) { self.fill($0, message) }
            }
        }
        return ids
    }

    public func forkChat(_ chatID: UUID, through messageID: UUID, now: Date) async throws -> Chat {
        let result: ForkResult = try mutate { try $0.forkChat(chatID, through: messageID, now: now) }
        for copy in result.attachmentCopies {
            let source = StoreLayout.attachmentURL(directory, id: copy.from)
            let destination = StoreLayout.attachmentURL(directory, id: copy.to)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
        try await perform {
            try self.upsert(entity: "Chat", id: result.chat.id.uuidString) { self.fill($0, result.chat) }
            for message in result.messages {
                try self.upsert(entity: "Message", id: message.id.uuidString) { self.fill($0, message) }
            }
            let snapshot = self.withDatabase { $0.snapshot }
            for attachment in snapshot.attachments where result.attachmentCopies.contains(where: { $0.to == attachment.id }) {
                try self.upsert(entity: "Attachment", id: attachment.id.uuidString) { self.fill($0, attachment) }
            }
        }
        return result.chat
    }

    public func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        withDatabase { $0.search(query, limit: limit) }
    }

    public func exportChat(_ chatID: UUID) async throws -> Data {
        let snapshot = try await snapshot()
        guard let chat = snapshot.chats.first(where: { $0.id == chatID }) else {
            throw RepositoryError.notFound("chat")
        }
        let project = snapshot.projects.first { $0.id == chat.projectID }
        let messages = snapshot.messages.filter { $0.chatID == chatID }.sorted { $0.ordinal < $1.ordinal }
        let ids = Set(messages.flatMap(\.attachmentIDs))
        let attachments = try snapshot.attachments.filter { ids.contains($0.id) }.map { attachment in
            let bytes = try Data(contentsOf: StoreLayout.attachmentURL(directory, id: attachment.id))
            return ExportedAttachment(attachment: attachment, base64: bytes.base64EncodedString())
        }
        let export = ChatExport(chat: chat, project: project, messages: messages, attachments: attachments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    public func importOwnExport(_ data: Data) async throws -> Chat {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(ChatExport.self, from: data)
        guard export.format == ChatExport.formatID else {
            throw RepositoryError.corruptStore("Unsupported export format")
        }
        if let project = export.project {
            try await saveProject(project)
        }
        try await saveChat(export.chat)
        for message in export.messages {
            try await saveMessage(message)
        }
        for item in export.attachments {
            guard let bytes = Data(base64Encoded: item.base64) else {
                throw RepositoryError.corruptStore("Attachment bytes were not valid")
            }
            try await saveAttachment(item.attachment, data: bytes)
        }
        return export.chat
    }

    public func backup(to directory: URL, now: Date) async throws {
        let snapshot = try await snapshot()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: StoreLayout.attachmentsDirectory(directory), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(BackupManifest(createdAt: now)).write(to: StoreLayout.manifestFile(directory), options: .atomic)
        try SnapshotCodec.encode(snapshot).write(to: StoreLayout.storeFile(directory), options: .atomic)
        for attachment in snapshot.attachments {
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

    public func restore(from directory: URL) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: StoreLayout.manifestFile(directory)))
        guard manifest.format == BackupManifest.formatID else {
            throw RepositoryError.corruptStore("Unsupported backup format")
        }
        let snapshot = try SnapshotCodec.decode(Data(contentsOf: StoreLayout.storeFile(directory)))
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
        lock.lock()
        database = WorkspaceDatabase(snapshot: snapshot)
        lock.unlock()
        try await perform { try self.replaceAll() }
    }

    public func ensureFirstRun(now: Date) async throws -> Bool {
        let created: Bool = mutate { $0.ensureFirstRun(now: now) }
        if created {
            try await perform { try self.replaceAll() }
        }
        return created
    }

    private func loadDatabase() async throws -> WorkspaceDatabase {
        try await perform { () -> WorkspaceDatabase in
            var database = WorkspaceDatabase()
            for object in try self.fetch("Project") { try database.upsertProject(self.project(object)) }
            for object in try self.fetch("Chat") { try database.upsertChat(self.chat(object)) }
            for object in try self.fetch("Message") { try database.upsertMessage(self.message(object)) }
            for object in try self.fetch("Attachment") { try database.upsertAttachment(self.attachment(object)) }
            for object in try self.fetch("Agent") { try database.upsertAgent(self.agent(object)) }
            for object in try self.fetch("Prompt") { try database.upsertPrompt(self.prompt(object)) }
            for object in try self.fetch("Workflow") { try database.upsertWorkflow(self.workflow(object)) }
            for object in try self.fetch("MCPServer") { try database.upsertMCPServer(self.server(object)) }
            return database
        }
    }

    private func replaceAll() throws {
        for name in entityNames {
            for object in try fetch(name) {
                context.delete(object)
            }
        }
        let snapshot = withDatabase { $0.snapshot }
        for project in snapshot.projects { try upsert(entity: "Project", id: project.id.uuidString) { self.fill($0, project) } }
        for chat in snapshot.chats { try upsert(entity: "Chat", id: chat.id.uuidString) { self.fill($0, chat) } }
        for message in snapshot.messages { try upsert(entity: "Message", id: message.id.uuidString) { self.fill($0, message) } }
        for attachment in snapshot.attachments { try upsert(entity: "Attachment", id: attachment.id.uuidString) { self.fill($0, attachment) } }
        for agent in snapshot.agents { try upsert(entity: "Agent", id: agent.id.uuidString) { self.fill($0, agent) } }
        for prompt in snapshot.prompts { try upsert(entity: "Prompt", id: prompt.id.uuidString) { self.fill($0, prompt) } }
        for workflow in snapshot.workflows { try upsert(entity: "Workflow", id: workflow.id.uuidString) { self.fill($0, workflow) } }
        for server in snapshot.mcpServers { try upsert(entity: "MCPServer", id: server.id.uuidString) { self.fill($0, server) } }
    }

    private func mutate<T>(_ body: (inout WorkspaceDatabase) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&database)
    }

    private func withDatabase<T>(_ body: (WorkspaceDatabase) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(database)
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            context.perform {
                do {
                    continuation.resume(returning: try body())
                } catch let error as RepositoryError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: RepositoryError.corruptStore(String(describing: error)))
                }
            }
        }
    }

    private func upsert(entity name: String, id: String, fill: (NSManagedObject) -> Void) throws {
        let object = try existing(entity: name, id: id) ?? NSEntityDescription.insertNewObject(forEntityName: name, into: context)
        object.setValue(id, forKey: "id")
        fill(object)
        try saveContext()
    }

    private func existing(entity name: String, id: String) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: name)
        request.predicate = NSPredicate(format: "id == %@", id)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func fetch(_ name: String) throws -> [NSManagedObject] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name))
    }

    private func saveContext() throws {
        if context.hasChanges {
            try context.save()
        }
    }

    private func fill(_ object: NSManagedObject, _ project: Project) {
        object.setValue(project.name, forKey: "name")
        object.setValue(project.instructions, forKey: "instructions")
        object.setValue(project.createdAt, forKey: "createdAt")
        object.setValue(project.updatedAt, forKey: "updatedAt")
    }

    private func fill(_ object: NSManagedObject, _ chat: Chat) {
        object.setValue(chat.projectID.uuidString, forKey: "projectID")
        object.setValue(chat.title, forKey: "title")
        object.setValue(chat.agentID?.uuidString, forKey: "agentID")
        object.setValue(chat.model.provider.rawValue, forKey: "provider")
        object.setValue(chat.model.name, forKey: "modelName")
        object.setValue(chat.createdAt, forKey: "createdAt")
        object.setValue(chat.updatedAt, forKey: "updatedAt")
        object.setValue(chat.forkedFromChatID?.uuidString, forKey: "forkedFromChatID")
        object.setValue(chat.forkedFromMessageID?.uuidString, forKey: "forkedFromMessageID")
    }

    private func fill(_ object: NSManagedObject, _ message: Message) {
        object.setValue(message.chatID.uuidString, forKey: "chatID")
        object.setValue(message.role.rawValue, forKey: "role")
        object.setValue(message.text, forKey: "text")
        object.setValue(message.reasoning, forKey: "reasoning")
        object.setValue(message.status.rawValue, forKey: "status")
        object.setValue(message.errorMessage, forKey: "errorMessage")
        object.setValue(message.retryable, forKey: "retryable")
        object.setValue(json(message.citations), forKey: "citationsJSON")
        object.setValue(json(message.toolCalls), forKey: "toolCallsJSON")
        object.setValue(json(message.toolResults), forKey: "toolResultsJSON")
        object.setValue(json(message.attachmentIDs), forKey: "attachmentIDsJSON")
        object.setValue(message.createdAt, forKey: "createdAt")
        object.setValue(Int64(message.ordinal), forKey: "ordinal")
    }

    private func fill(_ object: NSManagedObject, _ attachment: Attachment) {
        object.setValue(attachment.filename, forKey: "filename")
        object.setValue(attachment.mimeType, forKey: "mimeType")
        object.setValue(Int64(attachment.byteCount), forKey: "byteCount")
        object.setValue(attachment.relativePath, forKey: "relativePath")
    }

    private func fill(_ object: NSManagedObject, _ agent: Agent) {
        object.setValue(agent.name, forKey: "name")
        object.setValue(agent.systemPrompt, forKey: "systemPrompt")
        object.setValue(agent.model.provider.rawValue, forKey: "provider")
        object.setValue(agent.model.name, forKey: "modelName")
        object.setValue(agent.temperature, forKey: "temperature")
        object.setValue(json(agent.enabledToolNames), forKey: "enabledToolNamesJSON")
        object.setValue(json(agent.mcpServerIDs), forKey: "mcpServerIDsJSON")
    }

    private func fill(_ object: NSManagedObject, _ prompt: SavedPrompt) {
        object.setValue(prompt.title, forKey: "title")
        object.setValue(prompt.body, forKey: "body")
        object.setValue(prompt.createdAt, forKey: "createdAt")
    }

    private func fill(_ object: NSManagedObject, _ workflow: Workflow) {
        object.setValue(workflow.name, forKey: "name")
        object.setValue(workflow.template, forKey: "template")
        object.setValue(json(workflow.sources), forKey: "sourcesJSON")
        object.setValue(workflow.agentID?.uuidString, forKey: "agentID")
        object.setValue(workflow.model?.provider.rawValue, forKey: "provider")
        object.setValue(workflow.model?.name, forKey: "modelName")
    }

    private func fill(_ object: NSManagedObject, _ server: MCPServer) {
        object.setValue(server.name, forKey: "name")
        object.setValue(server.transport.rawValue, forKey: "transport")
        object.setValue(server.command, forKey: "command")
        object.setValue(json(server.arguments), forKey: "argumentsJSON")
        object.setValue(server.url, forKey: "url")
        object.setValue(server.enabled, forKey: "enabled")
    }

    private func project(_ object: NSManagedObject) throws -> Project {
        try Project(
            id: uuid(object, "id"),
            name: string(object, "name"),
            instructions: string(object, "instructions"),
            createdAt: date(object, "createdAt"),
            updatedAt: date(object, "updatedAt")
        )
    }

    private func chat(_ object: NSManagedObject) throws -> Chat {
        let provider = ProviderKind(rawValue: string(object, "provider")) ?? .ollama
        return try Chat(
            id: uuid(object, "id"),
            projectID: uuid(object, "projectID"),
            title: string(object, "title"),
            agentID: optionalUUID(object, "agentID"),
            model: ModelRef(provider: provider, name: string(object, "modelName")),
            createdAt: date(object, "createdAt"),
            updatedAt: date(object, "updatedAt"),
            forkedFromChatID: optionalUUID(object, "forkedFromChatID"),
            forkedFromMessageID: optionalUUID(object, "forkedFromMessageID")
        )
    }

    private func message(_ object: NSManagedObject) throws -> Message {
        try Message(
            id: uuid(object, "id"),
            chatID: uuid(object, "chatID"),
            role: MessageRole(rawValue: string(object, "role")) ?? .assistant,
            text: string(object, "text"),
            reasoning: string(object, "reasoning"),
            status: MessageStatus(rawValue: string(object, "status")) ?? .complete,
            errorMessage: object.value(forKey: "errorMessage") as? String,
            retryable: object.value(forKey: "retryable") as? Bool ?? false,
            citations: decode([Citation].self, string(object, "citationsJSON")),
            toolCalls: decode([ToolCallDraft].self, string(object, "toolCallsJSON")),
            toolResults: decode([ToolResult].self, string(object, "toolResultsJSON")),
            attachmentIDs: decode([UUID].self, string(object, "attachmentIDsJSON")),
            createdAt: date(object, "createdAt"),
            ordinal: Int(object.value(forKey: "ordinal") as? Int64 ?? 0)
        )
    }

    private func attachment(_ object: NSManagedObject) throws -> Attachment {
        try Attachment(
            id: uuid(object, "id"),
            filename: string(object, "filename"),
            mimeType: string(object, "mimeType"),
            byteCount: Int(object.value(forKey: "byteCount") as? Int64 ?? 0),
            relativePath: string(object, "relativePath")
        )
    }

    private func agent(_ object: NSManagedObject) throws -> Agent {
        let provider = ProviderKind(rawValue: string(object, "provider")) ?? .ollama
        return try Agent(
            id: uuid(object, "id"),
            name: string(object, "name"),
            systemPrompt: string(object, "systemPrompt"),
            model: ModelRef(provider: provider, name: string(object, "modelName")),
            temperature: object.value(forKey: "temperature") as? Double,
            enabledToolNames: decode([String].self, string(object, "enabledToolNamesJSON")),
            mcpServerIDs: decode([UUID].self, string(object, "mcpServerIDsJSON"))
        )
    }

    private func prompt(_ object: NSManagedObject) throws -> SavedPrompt {
        try SavedPrompt(
            id: uuid(object, "id"),
            title: string(object, "title"),
            body: string(object, "body"),
            createdAt: date(object, "createdAt")
        )
    }

    private func workflow(_ object: NSManagedObject) throws -> Workflow {
        let provider = (object.value(forKey: "provider") as? String).flatMap(ProviderKind.init(rawValue:))
        let modelName = object.value(forKey: "modelName") as? String
        let model = provider.flatMap { kind in modelName.map { ModelRef(provider: kind, name: $0) } }
        return try Workflow(
            id: uuid(object, "id"),
            name: string(object, "name"),
            template: string(object, "template"),
            sources: decode([WorkflowInputSource].self, string(object, "sourcesJSON")),
            agentID: optionalUUID(object, "agentID"),
            model: model
        )
    }

    private func server(_ object: NSManagedObject) throws -> MCPServer {
        try MCPServer(
            id: uuid(object, "id"),
            name: string(object, "name"),
            transport: MCPTransportKind(rawValue: string(object, "transport")) ?? .stdio,
            command: object.value(forKey: "command") as? String,
            arguments: decode([String].self, string(object, "argumentsJSON")),
            url: object.value(forKey: "url") as? String,
            enabled: object.value(forKey: "enabled") as? Bool ?? true
        )
    }

    private func json<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ raw: String) -> T where T: ExpressibleByArrayLiteral {
        if let value = try? JSONDecoder().decode(T.self, from: Data(raw.utf8)) {
            return value
        }
        return []
    }

    private func string(_ object: NSManagedObject, _ key: String) -> String {
        object.value(forKey: key) as? String ?? ""
    }

    private func date(_ object: NSManagedObject, _ key: String) -> Date {
        object.value(forKey: key) as? Date ?? Date(timeIntervalSince1970: 0)
    }

    private func uuid(_ object: NSManagedObject, _ key: String) throws -> UUID {
        guard let id = optionalUUID(object, key) else {
            throw RepositoryError.corruptStore("Missing \(key)")
        }
        return id
    }

    private func optionalUUID(_ object: NSManagedObject, _ key: String) -> UUID? {
        (object.value(forKey: key) as? String).flatMap(UUID.init(uuidString:))
    }
}
#endif
