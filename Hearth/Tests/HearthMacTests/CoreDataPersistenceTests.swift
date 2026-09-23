#if os(macOS)
import XCTest
import HearthCore
@testable import HearthMac

final class CoreDataPersistenceTests: XCTestCase {
    func testSQLiteRoundTripKeepsPartialStreamAcrossRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearth-coredata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messageID = UUID()

        do {
            let store = try await CoreDataChatStore(directory: directory)
            let created = try await store.ensureFirstRun(now: now)
            XCTAssertTrue(created)
            let project = Project(id: UUID(), name: "Notes", instructions: "", createdAt: now, updatedAt: now)
            try await store.saveProject(project)
            let chat = Chat(id: UUID(), projectID: project.id, title: "Draft", model: .defaultModel, createdAt: now, updatedAt: now)
            try await store.saveChat(chat)
            let attachment = Attachment(id: UUID(), filename: "photo.png", mimeType: "image/png", byteCount: 0, relativePath: "")
            try await store.saveAttachment(attachment, data: Data([0x89, 0x50, 0x4E, 0x47]))
            let message = Message(
                id: messageID,
                chatID: chat.id,
                role: .assistant,
                text: "partial answer",
                reasoning: "still thinking",
                status: .streaming,
                createdAt: now,
                ordinal: 0
            )
            try await store.saveMessage(message)
        }

        let reopened = try await CoreDataChatStore(directory: directory)
        let before = try await reopened.snapshot()
        XCTAssertEqual(before.messages.first { $0.id == messageID }?.text, "partial answer")
        XCTAssertEqual(before.messages.first { $0.id == messageID }?.reasoning, "still thinking")
        XCTAssertEqual(before.messages.first { $0.id == messageID }?.status, .streaming)
        let bytes = try await reopened.dataForAttachment(try XCTUnwrap(before.attachments.first?.id))
        XCTAssertEqual(bytes, Data([0x89, 0x50, 0x4E, 0x47]))

        let recovered = try await reopened.recoverInterruptedStreams()
        XCTAssertEqual(recovered, [messageID])
        let after = try await reopened.snapshot()
        let message = try XCTUnwrap(after.messages.first { $0.id == messageID })
        XCTAssertEqual(message.status, .interrupted)
        XCTAssertEqual(message.text, "partial answer")
        XCTAssertTrue(message.retryable)

        let second = try await reopened.recoverInterruptedStreams()
        XCTAssertTrue(second.isEmpty)

        let persisted = try await CoreDataChatStore(directory: directory)
        let stored = try await persisted.snapshot()
        XCTAssertEqual(stored.messages.first { $0.id == messageID }?.status, .interrupted)
        XCTAssertEqual(stored.messages.first { $0.id == messageID }?.text, "partial answer")
    }
}
#endif
