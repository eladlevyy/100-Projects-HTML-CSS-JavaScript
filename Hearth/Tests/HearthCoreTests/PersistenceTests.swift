import XCTest
@testable import HearthCore

final class PersistenceTests: XCTestCase {
    func testProjectChatAttachmentRoundTripAndRelaunch() async throws {
        let directory = try makeTempDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try SnapshotChatStore(directory: directory)
        let project = Project(id: UUID(), name: "Notes", instructions: "Be brief.", createdAt: now, updatedAt: now)
        try await store.saveProject(project)
        let chat = Chat(
            id: UUID(),
            projectID: project.id,
            title: "New chat",
            model: ModelRef(provider: .ollama, name: "llama3.2"),
            createdAt: now,
            updatedAt: now
        )
        try await store.saveChat(chat)
        let change = try TurnPreparation.beginSend(
            snapshot: await store.snapshot(),
            chatID: chat.id,
            userText: "Hello local store",
            attachmentIDs: [],
            now: now
        )
        try await store.apply(change)
        let attachment = Attachment(
            id: UUID(),
            filename: "note.txt",
            mimeType: "text/plain",
            byteCount: 0,
            relativePath: ""
        )
        var user = change.upsertMessages[0]
        user.attachmentIDs = [attachment.id]
        try await store.saveAttachment(attachment, data: Data("stored locally".utf8))
        try await store.saveMessage(user)

        let reopened = try SnapshotChatStore(directory: directory)
        let snapshot = await reopened.snapshot()
        XCTAssertEqual(snapshot.projects.map(\.name), ["Notes"])
        let attachmentBytes = try await reopened.dataForAttachment(attachment.id)
        XCTAssertEqual(attachmentBytes, Data("stored locally".utf8))
        let messages = snapshot.messages.filter { $0.chatID == chat.id }.sorted { $0.ordinal < $1.ordinal }
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages[0].text, "Hello local store")
        XCTAssertEqual(messages[1].status, .streaming)
        XCTAssertEqual(snapshot.chats.first?.title, "Hello local store")
    }

    func testForkStopsAtSelectedMessageAndCopiesAttachment() async throws {
        let directory = try makeTempDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try SnapshotChatStore(directory: directory)
        let project = Project(id: UUID(), name: "Inbox", instructions: "", createdAt: now, updatedAt: now)
        try await store.saveProject(project)
        let chat = Chat(id: UUID(), projectID: project.id, title: "Branch", model: .defaultModel, createdAt: now, updatedAt: now)
        try await store.saveChat(chat)
        let attachment = Attachment(id: UUID(), filename: "a.txt", mimeType: "text/plain", byteCount: 0, relativePath: "")
        try await store.saveAttachment(attachment, data: Data("alpha".utf8))
        let first = Message(id: UUID(), chatID: chat.id, role: .user, text: "keep", status: .complete, attachmentIDs: [attachment.id], createdAt: now, ordinal: 0)
        let second = Message(id: UUID(), chatID: chat.id, role: .assistant, text: "also keep", status: .complete, createdAt: now, ordinal: 1)
        let third = Message(id: UUID(), chatID: chat.id, role: .user, text: "drop me", status: .complete, createdAt: now, ordinal: 2)
        try await store.saveMessage(first)
        try await store.saveMessage(second)
        try await store.saveMessage(third)

        let forked = try await store.forkChat(chat.id, through: second.id, now: now.addingTimeInterval(5))
        let snapshot = await store.snapshot()
        let copied = snapshot.messages.filter { $0.chatID == forked.id }.sorted { $0.ordinal < $1.ordinal }
        XCTAssertEqual(copied.map(\.text), ["keep", "also keep"])
        XCTAssertEqual(forked.forkedFromChatID, chat.id)
        XCTAssertEqual(forked.forkedFromMessageID, second.id)
        let copiedAttachment = try XCTUnwrap(copied[0].attachmentIDs.first)
        XCTAssertNotEqual(copiedAttachment, attachment.id)
        let copiedBytes = try await store.dataForAttachment(copiedAttachment)
        XCTAssertEqual(copiedBytes, Data("alpha".utf8))
        XCTAssertEqual(snapshot.messages.filter { $0.chatID == chat.id }.count, 3)
    }

    func testFullTextSearchAcrossChats() async throws {
        let directory = try makeTempDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try SnapshotChatStore(directory: directory)
        let project = Project(id: UUID(), name: "Search", instructions: "", createdAt: now, updatedAt: now)
        try await store.saveProject(project)
        let firstChat = Chat(id: UUID(), projectID: project.id, title: "One", model: .defaultModel, createdAt: now, updatedAt: now)
        let secondChat = Chat(id: UUID(), projectID: project.id, title: "Two", model: .defaultModel, createdAt: now, updatedAt: now)
        try await store.saveChat(firstChat)
        try await store.saveChat(secondChat)
        try await store.saveMessage(Message(id: UUID(), chatID: firstChat.id, role: .assistant, text: "The cedar key stays in the drawer.", status: .complete, createdAt: now, ordinal: 0))
        try await store.saveMessage(Message(id: UUID(), chatID: secondChat.id, role: .assistant, text: "Nothing about storage here.", status: .complete, createdAt: now, ordinal: 0))
        let hits = await store.search("cedar key", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].chatID, firstChat.id)
        XCTAssertTrue(hits[0].snippet.localizedCaseInsensitiveContains("cedar"))
    }

    func testExportOmitsSecretsAndRoundTripsAttachments() async throws {
        let directory = try makeTempDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try SnapshotChatStore(directory: directory)
        let secrets = MemorySecretStore()
        try secrets.save(account: CredentialAccount.openAI, secret: "sk-test-secret")
        let project = Project(id: UUID(), name: "Export", instructions: "", createdAt: now, updatedAt: now)
        let chat = Chat(id: UUID(), projectID: project.id, title: "Packed", model: .defaultModel, createdAt: now, updatedAt: now)
        try await store.saveProject(project)
        try await store.saveChat(chat)
        let attachment = Attachment(id: UUID(), filename: "pic.txt", mimeType: "text/plain", byteCount: 0, relativePath: "")
        try await store.saveAttachment(attachment, data: Data("bytes".utf8))
        try await store.saveMessage(Message(id: UUID(), chatID: chat.id, role: .user, text: "pack this", status: .complete, attachmentIDs: [attachment.id], createdAt: now, ordinal: 0))
        let data = try await store.exportChat(chat.id)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("sk-test-secret"))
        XCTAssertTrue(json.contains("hearth.chat.v1"))
        let loaded = try secrets.load(account: CredentialAccount.openAI)
        XCTAssertEqual(loaded, "sk-test-secret")

        let other = try SnapshotChatStore(directory: try makeTempDirectory())
        let imported = try await other.importOwnExport(data)
        XCTAssertEqual(imported.id, chat.id)
        let importedBytes = try await other.dataForAttachment(attachment.id)
        XCTAssertEqual(importedBytes, Data("bytes".utf8))
    }

    func testBackupRestoreReplacesWorkspace() async throws {
        let directory = try makeTempDirectory()
        let backup = try makeTempDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try SnapshotChatStore(directory: directory)
        let project = Project(id: UUID(), name: "Keep", instructions: "local", createdAt: now, updatedAt: now)
        try await store.saveProject(project)
        let chat = Chat(id: UUID(), projectID: project.id, title: "Saved", model: .defaultModel, createdAt: now, updatedAt: now)
        try await store.saveChat(chat)
        let attachment = Attachment(id: UUID(), filename: "a.bin", mimeType: "text/plain", byteCount: 0, relativePath: "")
        try await store.saveAttachment(attachment, data: Data("backup-bytes".utf8))
        try await store.backup(to: backup, now: now)

        try await store.saveProject(Project(id: UUID(), name: "Temporary", instructions: "", createdAt: now, updatedAt: now))
        try await store.restore(from: backup)
        let names = await store.snapshot().projects.map(\.name)
        XCTAssertEqual(names, ["Keep"])
        let restoredBytes = try await store.dataForAttachment(attachment.id)
        XCTAssertEqual(restoredBytes, Data("backup-bytes".utf8))
    }

    func testInterruptedStreamRecoveredOnRelaunch() async throws {
        let directory = try makeTempDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try SnapshotChatStore(directory: directory)
        let project = Project(id: UUID(), name: "Inbox", instructions: "", createdAt: now, updatedAt: now)
        let chat = Chat(id: UUID(), projectID: project.id, title: "Live", model: .defaultModel, createdAt: now, updatedAt: now)
        try await store.saveProject(project)
        try await store.saveChat(chat)
        let partial = Message(
            id: UUID(),
            chatID: chat.id,
            role: .assistant,
            text: "partial answer",
            reasoning: "thinking",
            status: .streaming,
            createdAt: now,
            ordinal: 1
        )
        try await store.saveMessage(partial)
        let reopened = try SnapshotChatStore(directory: directory)
        let recovered = try await reopened.recoverInterruptedStreams()
        XCTAssertEqual(recovered, [partial.id])
        let message = await reopened.snapshot().messages.first { $0.id == partial.id }
        XCTAssertEqual(message?.status, .interrupted)
        XCTAssertEqual(message?.text, "partial answer")
        XCTAssertEqual(message?.reasoning, "thinking")
        XCTAssertEqual(message?.retryable, true)
        let third = try SnapshotChatStore(directory: directory)
        let again = try await third.recoverInterruptedStreams()
        XCTAssertTrue(again.isEmpty)
        let reloaded = await third.snapshot()
        XCTAssertEqual(reloaded.messages.first?.status, .interrupted)
    }

    func testTemporaryStoreFileRecoveredWhenPrimaryMissing() async throws {
        let directory = try makeTempDirectory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try SnapshotChatStore(directory: directory)
        try await store.saveProject(Project(id: UUID(), name: "Recovered", instructions: "", createdAt: now, updatedAt: now))
        let primary = StoreLayout.storeFile(directory)
        let temporary = StoreLayout.storeTemporaryFile(directory)
        try FileManager.default.copyItem(at: primary, to: temporary)
        try FileManager.default.removeItem(at: primary)
        let reopened = try SnapshotChatStore(directory: directory)
        let recovered = await reopened.snapshot()
        XCTAssertEqual(recovered.projects.map(\.name), ["Recovered"])
    }

    func testLargeHistorySearchAndSidebarStayResponsive() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let projectCount = 40
        let chatsPerProject = 25
        var projects: [Project] = []
        var chats: [Chat] = []
        var messages: [Message] = []
        for projectIndex in 0..<projectCount {
            let project = Project(id: UUID(), name: "Project \(projectIndex)", instructions: "", createdAt: now, updatedAt: now)
            projects.append(project)
            for chatIndex in 0..<chatsPerProject {
                let chat = Chat(
                    id: UUID(),
                    projectID: project.id,
                    title: "Chat \(projectIndex)-\(chatIndex)",
                    model: .defaultModel,
                    createdAt: now,
                    updatedAt: now.addingTimeInterval(TimeInterval(chatIndex))
                )
                chats.append(chat)
                messages.append(contentsOf: HistorySeeder.messages(chatID: chat.id, count: 4, now: now))
            }
        }
        messages.append(Message(
            id: UUID(),
            chatID: chats[0].id,
            role: .assistant,
            text: "unique needle phrase for search",
            status: .complete,
            createdAt: now,
            ordinal: 99
        ))
        let probe = PerformanceProbe()
        let database = WorkspaceDatabase(snapshot: WorkspaceSnapshot(projects: projects, chats: chats, messages: messages))
        probe.measure(.navigation) {
            let rows = SidebarLayout.rows(projects: projects, chats: chats, collapsed: [], filter: "Chat 3-")
            XCTAssertFalse(rows.isEmpty)
        }
        probe.measure(.scrolling) {
            let range = TranscriptWindow.visibleRange(total: messages.count, anchor: messages.count / 2, viewport: 30, overscan: 8)
            XCTAssertLessThanOrEqual(range.count, 46)
        }
        var hits: [SearchHit] = []
        probe.measure(.streaming) {
            hits = database.search("unique needle", limit: 5)
        }
        XCTAssertEqual(hits.count, 1)
        let report = probe.report()
        XCTAssertLessThan(report.maxMilliseconds(for: .navigation) ?? 1_000, 500)
        XCTAssertLessThan(report.maxMilliseconds(for: .scrolling) ?? 1_000, 500)
        XCTAssertLessThan(report.maxMilliseconds(for: .streaming) ?? 1_000, 1_000)
        _ = database.snapshot.messages.count
    }

    func testFirstRunAndSecretAccountsStayIsolated() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = FirstRun.bootstrap(now: now)
        XCTAssertEqual(snapshot.projects.map(\.name), ["Inbox"])
        XCTAssertEqual(snapshot.chats.count, 1)
        XCTAssertFalse(snapshot.messages[0].text.contains("sk-"))
        let secrets = MemorySecretStore()
        try secrets.save(account: CredentialAccount.openAI, secret: "one")
        try secrets.save(account: CredentialAccount.anthropic, secret: "two")
        try secrets.delete(account: CredentialAccount.openAI)
        XCTAssertNil(try secrets.load(account: CredentialAccount.openAI))
        XCTAssertEqual(try secrets.load(account: CredentialAccount.anthropic), "two")
        let credentials = try CredentialAccount.credentials(from: secrets, ollamaBaseURL: URL(string: "http://127.0.0.1:11434")!)
        XCTAssertNil(credentials.openAIKey)
        XCTAssertEqual(credentials.anthropicKey, "two")
    }
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
