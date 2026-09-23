import XCTest
@testable import HearthCore

final class StreamingStateTests: XCTestCase {
    func testDeltasAccumulateCitationsToolsAndReasoning() {
        var snapshot = StreamSnapshot()
        let citation = Citation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Doc", url: "https://example.com", snippet: "line")
        let events: [StreamEvent] = [
            .started,
            .reasoning("Think"),
            .reasoning(" more"),
            .text("Hello"),
            .text(" there"),
            .citation(citation),
            .toolCallDelta(id: "call_1", name: "lookup", argumentsDelta: "{\"q\":"),
            .toolCallDelta(id: "call_1", name: nil, argumentsDelta: "\"x\"}"),
            .completed(finishReason: "tool_calls"),
        ]
        for event in events {
            snapshot = StreamingReducer.reduce(snapshot, event)
        }
        XCTAssertEqual(snapshot.phase, .completed)
        XCTAssertEqual(snapshot.text, "Hello there")
        XCTAssertEqual(snapshot.reasoning, "Think more")
        XCTAssertEqual(snapshot.citations, [citation])
        XCTAssertEqual(snapshot.toolCalls, [ToolCallDraft(id: "call_1", name: "lookup", arguments: "{\"q\":\"x\"}")])
        XCTAssertEqual(snapshot.finishReason, "tool_calls")
    }

    func testCancelKeepsPartialAndIgnoresLaterDeltas() {
        var snapshot = StreamingReducer.reduce(StreamSnapshot(), .text("Partial"))
        snapshot = StreamingReducer.reduce(snapshot, .cancelled)
        snapshot = StreamingReducer.reduce(snapshot, .text(" ignored"))
        snapshot = StreamingReducer.reduce(snapshot, .completed(finishReason: "stop"))
        XCTAssertEqual(snapshot.phase, .cancelled)
        XCTAssertEqual(snapshot.text, "Partial")
        XCTAssertEqual(StreamStatusMap.messageStatus(phase: snapshot.phase, hasContent: snapshot.hasContent), .partial)
        XCTAssertTrue(StreamStatusMap.retryable(phase: snapshot.phase, failure: nil))
        let message = apply(snapshot, to: Message(
            id: UUID(),
            chatID: UUID(),
            role: .assistant,
            text: "",
            status: .streaming,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            ordinal: 1
        ))
        XCTAssertEqual(message.text, "Partial")
        XCTAssertEqual(message.status, .partial)
        XCTAssertEqual(message.retryable, true)
    }

    func testRateLimitKeepsPartialAndIsRetryable() {
        var snapshot = StreamingReducer.reduce(StreamSnapshot(), .text("Kept"))
        let failure = ProviderFailure.rateLimited(retryAfterSeconds: 9, message: "Rate limit reached")
        snapshot = StreamingReducer.reduce(snapshot, .failed(failure))
        XCTAssertEqual(snapshot.text, "Kept")
        XCTAssertEqual(snapshot.failure, failure)
        XCTAssertTrue(failure.isRetryable)
        XCTAssertEqual(StreamStatusMap.messageStatus(phase: snapshot.phase, hasContent: snapshot.hasContent), .partial)
        XCTAssertTrue(snapshot.failure?.displayMessage.contains("9s") == true)
    }

    func testUnauthorizedIsNotRetryable() {
        let failure = ProviderFailure.unauthorized(message: "Add an OpenAI API key in Settings.")
        let snapshot = StreamingReducer.reduce(StreamSnapshot(), .failed(failure))
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertFalse(failure.isRetryable)
        XCTAssertEqual(StreamStatusMap.messageStatus(phase: snapshot.phase, hasContent: snapshot.hasContent), .failed)
    }

    func testInterruptedKeepsText() {
        var snapshot = StreamingReducer.reduce(StreamSnapshot(), .reasoning("why"))
        snapshot = StreamingReducer.reduce(snapshot, .text("because"))
        snapshot = StreamingReducer.reduce(snapshot, .interrupted)
        snapshot = StreamingReducer.reduce(snapshot, .text("late"))
        XCTAssertEqual(snapshot.phase, .interrupted)
        XCTAssertEqual(snapshot.text, "because")
        XCTAssertEqual(snapshot.reasoning, "why")
        XCTAssertEqual(StreamStatusMap.messageStatus(phase: snapshot.phase, hasContent: true), .interrupted)
    }

    func testRunnerCompletesOpenAIStream() async {
        let request = ChatRequest(
            model: ModelRef(provider: .openAI, name: "gpt-4o"),
            messages: [ProviderMessage(role: .user, text: "Hi")]
        )
        let client = ScriptedStreamingClient(lines: [
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"He\"}}]}",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"llo\"}}]}",
            "data: [DONE]",
        ])
        let snapshot = await ChatTurnRunner.run(
            request: request,
            credentials: ProviderCredentials(openAIKey: "sk-test"),
            client: client
        )
        XCTAssertEqual(snapshot.phase, .completed)
        XCTAssertEqual(snapshot.text, "Hello")
    }

    func testRunnerCancellationKeepsPartial() async {
        let request = ChatRequest(
            model: ModelRef(provider: .ollama, name: "llama3.2"),
            messages: [ProviderMessage(role: .user, text: "Hi")]
        )
        let snapshot = await ChatTurnRunner.run(
            request: request,
            credentials: ProviderCredentials(),
            client: CancelAfterPartialClient()
        )
        XCTAssertEqual(snapshot.phase, .cancelled)
        XCTAssertEqual(snapshot.text, "Partial")
    }

    func testRunnerUnexpectedEndIsInterruptedAndRateLimitFails() async {
        let request = ChatRequest(
            model: ModelRef(provider: .openAI, name: "gpt-4o"),
            messages: [ProviderMessage(role: .user, text: "Hi")]
        )
        let credentials = ProviderCredentials(openAIKey: "sk-test")
        let interrupted = await ChatTurnRunner.run(
            request: request,
            credentials: credentials,
            client: ScriptedStreamingClient(lines: [
                "data: {\"choices\":[{\"delta\":{\"content\":\"Partial\"}}]}",
            ])
        )
        XCTAssertEqual(interrupted.phase, .interrupted)
        XCTAssertEqual(interrupted.text, "Partial")

        let limited = await ChatTurnRunner.run(
            request: request,
            credentials: credentials,
            client: ScriptedStreamingClient(lines: [
                "data: {\"choices\":[{\"delta\":{\"content\":\"Kept\"}}]}",
                "data: {\"error\":{\"message\":\"Rate limit reached\",\"code\":\"rate_limit_exceeded\"}}",
            ])
        )
        XCTAssertEqual(limited.phase, .failed)
        XCTAssertEqual(limited.text, "Kept")
        XCTAssertEqual(limited.failure?.isRetryable, true)
    }

    func testMissingKeyFailsBeforeStreaming() async {
        let snapshot = await ChatTurnRunner.run(
            request: ChatRequest(model: ModelRef(provider: .anthropic, name: "claude-sonnet-4-5"), messages: []),
            credentials: ProviderCredentials(),
            client: ScriptedStreamingClient(lines: [])
        )
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.failure, .unauthorized(message: "Add an Anthropic API key in Settings."))
    }

    func testCoalescerLimitsEmitRateAndWindowStaysBounded() {
        var coalescer = StreamCoalescer(intervalMS: 30)
        var emits = 0
        for index in 0..<100 {
            if coalescer.push(delta: "x", nowMS: Double(index)) != nil {
                emits += 1
            }
        }
        XCTAssertLessThan(emits, 20)
        XCTAssertEqual(coalescer.push(delta: "a", nowMS: 0), nil)
        let flushed = coalescer.flush(nowMS: 200)
        XCTAssertEqual(flushed?.hasSuffix("a"), true)

        let range = TranscriptWindow.visibleRange(total: 10_000, anchor: 5_000, viewport: 40, overscan: 8)
        XCTAssertLessThanOrEqual(range.count, 56)
        XCTAssertTrue(range.contains(5_000))
        XCTAssertEqual(TranscriptWindow.visibleRange(total: 0, anchor: 0, viewport: 20, overscan: 4), 0..<0)
    }

    func testComposerEditsDoNotRequireTranscript() {
        var editor = ComposerEditor()
        editor.insert("h")
        editor.insert("i")
        XCTAssertEqual(editor.text, "hi")
        editor.clear()
        XCTAssertEqual(editor.text, "")
    }

    func testMarkdownPresentationOfStreamedMessage() {
        let message = Message(
            id: UUID(),
            chatID: UUID(),
            role: .assistant,
            text: """
            # Title

            See `code` and:

            ```swift
            let value = 1
            ```

            - one
            - two

            ![plot](attachment://plot.png)
            """,
            reasoning: "checked the figure",
            status: .partial,
            citations: [Citation(title: "Source", url: "https://example.com/a")],
            toolCalls: [ToolCallDraft(id: "1", name: "lookup", arguments: "{}")],
            toolResults: [ToolResult(id: "1", name: "lookup", arguments: "{}", output: "42", isError: false)],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            ordinal: 1
        )
        let presented = TranscriptPresenter.present(message)
        XCTAssertTrue(presented.blocks.contains(.heading(level: 1, text: "Title")))
        XCTAssertTrue(presented.blocks.contains(.code(language: "swift", code: "let value = 1")))
        XCTAssertTrue(presented.blocks.contains(.bulletList(["one", "two"])))
        XCTAssertTrue(presented.blocks.contains(.image(alt: "plot", source: "attachment://plot.png")))
        XCTAssertEqual(presented.reasoning, "checked the figure")
        XCTAssertEqual(presented.citations.first?.url, "https://example.com/a")
        XCTAssertEqual(presented.toolResults.first?.output, "42")
        XCTAssertEqual(presented.status, .partial)
    }

    func testRetryAndRegeneratePreparation() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let chat = Chat(id: UUID(), projectID: UUID(), title: "T", model: .defaultModel, createdAt: now, updatedAt: now)
        let user = Message(id: UUID(), chatID: chat.id, role: .user, text: "Question", status: .complete, createdAt: now, ordinal: 0)
        let assistant = Message(id: UUID(), chatID: chat.id, role: .assistant, text: "Old", status: .partial, retryable: true, createdAt: now, ordinal: 1)
        let snapshot = WorkspaceSnapshot(chats: [chat], messages: [user, assistant])
        let retried = try TurnPreparation.retry(snapshot: snapshot, chatID: chat.id, now: now)
        XCTAssertEqual(retried.assistantMessage.id, assistant.id)
        XCTAssertEqual(retried.assistantMessage.text, "")
        XCTAssertEqual(retried.assistantMessage.status, .streaming)
        XCTAssertEqual(retried.contextMessages.map(\.text), ["Question"])

        let regenerated = try TurnPreparation.regenerate(snapshot: snapshot, chatID: chat.id, now: now)
        XCTAssertNotEqual(regenerated.assistantMessage.id, assistant.id)
        XCTAssertEqual(regenerated.deleteMessageIDs, [assistant.id])
        XCTAssertEqual(regenerated.assistantMessage.ordinal, assistant.ordinal)
        XCTAssertEqual(regenerated.contextMessages.map(\.id), [user.id])

        let complete = Message(id: UUID(), chatID: chat.id, role: .assistant, text: "Done", status: .complete, createdAt: now, ordinal: 1)
        let doneSnapshot = WorkspaceSnapshot(chats: [chat], messages: [user, complete])
        XCTAssertThrowsError(try TurnPreparation.retry(snapshot: doneSnapshot, chatID: chat.id, now: now)) { error in
            XCTAssertEqual(error as? RepositoryError, .nothingToRetry)
        }
    }
}

private struct CancelAfterPartialClient: StreamingHTTPClient {
    func lines(for request: ProviderHTTPRequest, provider: ProviderKind) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("{\"message\":{\"role\":\"assistant\",\"content\":\"Partial\"},\"done\":false}")
            continuation.finish(throwing: CancellationError())
        }
    }
}
