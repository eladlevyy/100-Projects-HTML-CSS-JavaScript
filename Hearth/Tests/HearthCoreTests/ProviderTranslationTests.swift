import XCTest
@testable import HearthCore

final class ProviderTranslationTests: XCTestCase {
    func testOpenAIRequestCarriesImagesToolsAndBearerKey() throws {
        let request = sampleRequest(provider: .openAI, model: "gpt-4o")
        let http = try ProviderTranslator.makeRequest(
            chat: request,
            credentials: ProviderCredentials(openAIKey: "sk-openai")
        )
        XCTAssertEqual(http.url.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(http.headers["Authorization"], "Bearer sk-openai")
        XCTAssertNil(http.headers["x-api-key"])
        let json = try http.jsonBody()
        XCTAssertEqual(json["model"]?.stringValue, "gpt-4o")
        XCTAssertEqual(json["stream"]?.boolValue, true)
        XCTAssertEqual(json["temperature"]?.doubleValue, 0.2)
        let user = try XCTUnwrap(json["messages"]?.arrayValue?.last)
        let imageURL = user["content"]?.arrayValue?.last?["image_url"]?["url"]?.stringValue
        XCTAssertEqual(imageURL, "data:image/png;base64,aGVsbG8=")
        XCTAssertEqual(json["tools"]?.arrayValue?.first?["function"]?["name"]?.stringValue, "lookup")
        XCTAssertEqual(json["tools"]?.arrayValue?.first?["function"]?["parameters"]?["type"]?.stringValue, "object")
    }

    func testOpenAIStreamDecodesReasoningToolsAndCitations() {
        var decoder = ProviderStreamDecoder(provider: .openAI)
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Because \"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Answer\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"lookup\",\"arguments\":\"\"}}]}}]}",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"q\\\":1}\"}}]}}]}",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":null}]}",
            "data: {\"choices\":[{\"delta\":{\"annotations\":[{\"url_citation\":{\"url\":\"https://example.com\",\"title\":\"Example\"}}]}}]}",
            "data: [DONE]",
        ]
        var events: [StreamEvent] = []
        for line in lines {
            events.append(contentsOf: decoder.decode(line))
        }
        XCTAssertTrue(events.contains(.reasoning("Because ")))
        XCTAssertTrue(events.contains(.text("Answer")))
        XCTAssertTrue(events.contains(.toolCallDelta(id: "call_1", name: "lookup", argumentsDelta: "")))
        XCTAssertTrue(events.contains(.toolCallDelta(id: "call_1", name: nil, argumentsDelta: "{\"q\":1}")))
        XCTAssertEqual(events.compactMap { event -> String? in
            if case .citation(let citation) = event { return citation.url }
            return nil
        }, ["https://example.com"])
        XCTAssertTrue(events.contains(.completed(finishReason: "stop")))
    }

    func testAnthropicRequestAndThinkingStream() throws {
        let http = try ProviderTranslator.makeRequest(
            chat: sampleRequest(provider: .anthropic, model: "claude-sonnet-4-5"),
            credentials: ProviderCredentials(anthropicKey: "sk-ant")
        )
        XCTAssertEqual(http.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(http.headers["x-api-key"], "sk-ant")
        XCTAssertEqual(http.headers["anthropic-version"], "2023-06-01")
        XCTAssertNil(http.headers["Authorization"])
        let json = try http.jsonBody()
        XCTAssertEqual(json["system"]?.stringValue, "Be brief.")
        XCTAssertEqual(json["max_tokens"]?.doubleValue, 8192)
        let content = json["messages"]?.arrayValue?.first?["content"]?.arrayValue
        XCTAssertEqual(content?.contains { $0["type"]?.stringValue == "image" }, true)
        XCTAssertEqual(content?.first { $0["type"]?.stringValue == "image" }?["source"]?["media_type"]?.stringValue, "image/png")
        XCTAssertFalse(json["messages"]?.arrayValue?.contains { $0["role"]?.stringValue == "system" } ?? true)

        var decoder = ProviderStreamDecoder(provider: .anthropic)
        let lines = [
            "event: content_block_start",
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"lookup\",\"input\":{}}}",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"q\\\":1}\"}}",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Consider \"}}",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"citations_delta\",\"citation\":{\"type\":\"web_search_result_location\",\"url\":\"https://example.com/doc\",\"title\":\"Doc\",\"cited_text\":\"snippet\"}}}",
            "event: message_stop",
            "data: {\"type\":\"message_stop\"}",
        ]
        var events: [StreamEvent] = []
        for line in lines { events.append(contentsOf: decoder.decode(line)) }
        var snapshot = StreamSnapshot()
        for event in events { snapshot = StreamingReducer.reduce(snapshot, event) }
        XCTAssertEqual(snapshot.phase, .completed)
        XCTAssertEqual(snapshot.reasoning, "Consider ")
        XCTAssertEqual(snapshot.text, "Hi")
        XCTAssertEqual(snapshot.toolCalls.first?.id, "toolu_1")
        XCTAssertEqual(snapshot.toolCalls.first?.name, "lookup")
        XCTAssertEqual(snapshot.toolCalls.first?.arguments, "{\"q\":1}")
        XCTAssertEqual(snapshot.citations.first?.snippet, "snippet")
    }

    func testGeminiAndOllamaTranslation() throws {
        let gemini = try ProviderTranslator.makeRequest(
            chat: sampleRequest(provider: .gemini, model: "gemini-2.5-flash"),
            credentials: ProviderCredentials(geminiKey: "gem-key")
        )
        let components = try XCTUnwrap(URLComponents(url: gemini.url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "generativelanguage.googleapis.com")
        XCTAssertTrue(components.path.contains("gemini-2.5-flash:streamGenerateContent"))
        XCTAssertEqual(components.queryItems?.first { $0.name == "alt" }?.value, "sse")
        XCTAssertEqual(components.queryItems?.first { $0.name == "key" }?.value, "gem-key")
        let geminiJSON = try gemini.jsonBody()
        XCTAssertEqual(geminiJSON["systemInstruction"]?["parts"]?.arrayValue?.first?["text"]?.stringValue, "Be brief.")
        XCTAssertEqual(geminiJSON["contents"]?.arrayValue?.first?["role"]?.stringValue, "user")
        XCTAssertEqual(
            geminiJSON["contents"]?.arrayValue?.first?["parts"]?.arrayValue?.last?["inlineData"]?["mimeType"]?.stringValue,
            "image/png"
        )
        XCTAssertEqual(geminiJSON["generationConfig"]?["temperature"]?.doubleValue, 0.2)

        var geminiDecoder = ProviderStreamDecoder(provider: .gemini)
        let geminiEvents = geminiDecoder.decode("data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hi\"},{\"thought\":true,\"text\":\"Why\"},{\"functionCall\":{\"name\":\"lookup\",\"args\":{\"q\":1}}}]},\"finishReason\":\"STOP\",\"citationMetadata\":{\"citationSources\":[{\"uri\":\"https://example.com/g\",\"title\":\"G\"}]}}]}")
        XCTAssertTrue(geminiEvents.contains(.text("Hi")))
        XCTAssertTrue(geminiEvents.contains(.reasoning("Why")))
        XCTAssertTrue(geminiEvents.contains(.completed(finishReason: "STOP")))

        let ollama = try ProviderTranslator.makeRequest(
            chat: sampleRequest(provider: .ollama, model: "llama3.2"),
            credentials: ProviderCredentials(ollamaBaseURL: URL(string: "http://127.0.0.1:11434/")!)
        )
        XCTAssertEqual(ollama.url.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertNil(ollama.headers["Authorization"])
        let ollamaJSON = try ollama.jsonBody()
        XCTAssertEqual(ollamaJSON["messages"]?.arrayValue?.last?["images"]?.arrayValue?.first?.stringValue, "aGVsbG8=")
        var ollamaDecoder = ProviderStreamDecoder(provider: .ollama)
        let ollamaEvents = [
            "{\"message\":{\"role\":\"assistant\",\"thinking\":\"hmm\",\"content\":\"He\"},\"done\":false}",
            "{\"message\":{\"role\":\"assistant\",\"content\":\"llo\"},\"done\":true}",
        ].flatMap { ollamaDecoder.decode($0) }
        var snapshot = StreamSnapshot()
        for event in ollamaEvents { snapshot = StreamingReducer.reduce(snapshot, event) }
        XCTAssertEqual(snapshot.text, "Hello")
        XCTAssertEqual(snapshot.reasoning, "hmm")
        XCTAssertEqual(snapshot.phase, .completed)
    }

    func testFailureMappingForRateLimitsAndMissingKeys() throws {
        let limited = ProviderTranslator.decodeFailure(
            provider: .openAI,
            status: 429,
            headers: ["Retry-After": "12"],
            body: Data("{\"error\":{\"message\":\"Rate limit reached\"}}".utf8)
        )
        XCTAssertEqual(limited, .rateLimited(retryAfterSeconds: 12, message: "Rate limit reached"))
        XCTAssertTrue(limited.isRetryable)

        let denied = ProviderTranslator.decodeFailure(
            provider: .anthropic,
            status: 401,
            headers: [:],
            body: Data("{\"error\":{\"message\":\"invalid key\"}}".utf8)
        )
        XCTAssertEqual(denied, .unauthorized(message: "invalid key"))
        XCTAssertFalse(denied.isRetryable)

        XCTAssertThrowsError(try ProviderTranslator.makeRequest(
            chat: sampleRequest(provider: .gemini, model: "gemini-2.5-flash"),
            credentials: ProviderCredentials()
        )) { error in
            XCTAssertEqual(error as? ProviderFailure, .unauthorized(message: "Add a Google Gemini API key in Settings."))
        }
    }

    func testPromptAssemblySeparatesSystemImagesAndToolResults() throws {
        let chat = Chat(id: UUID(), projectID: UUID(), title: "T", model: ModelRef(provider: .openAI, name: "gpt-4o"), createdAt: Date(), updatedAt: Date())
        let project = Project(id: chat.projectID, name: "P", instructions: "Project rule", createdAt: Date(), updatedAt: Date())
        let agent = Agent(id: UUID(), name: "A", systemPrompt: "Agent rule", model: chat.model, temperature: 0.3)
        let attachment = Attachment(id: UUID(), filename: "shot.png", mimeType: "image/png", byteCount: 5, relativePath: "attachments/x")
        let note = Attachment(id: UUID(), filename: "note.txt", mimeType: "text/plain", byteCount: 4, relativePath: "attachments/y")
        let user = Message(id: UUID(), chatID: chat.id, role: .user, text: "Look", status: .complete, attachmentIDs: [attachment.id, note.id], createdAt: Date(), ordinal: 0)
        let assistant = Message(
            id: UUID(),
            chatID: chat.id,
            role: .assistant,
            text: "Calling",
            status: .complete,
            toolCalls: [ToolCallDraft(id: "call_1", name: "lookup", arguments: "{\"q\":1}")],
            toolResults: [ToolResult(id: "call_1", name: "lookup", arguments: "{\"q\":1}", output: "found", isError: false)],
            createdAt: Date(),
            ordinal: 1
        )
        let request = PromptAssembly.request(
            chat: chat,
            project: project,
            agent: agent,
            messages: [user, assistant],
            attachments: [attachment, note],
            attachmentBytes: [attachment.id: Data("hello".utf8), note.id: Data("note".utf8)],
            tools: [ToolDefinition(name: "lookup", description: "Lookup", jsonSchema: "{\"type\":\"object\"}")]
        )
        XCTAssertEqual(request.messages.first?.text, "Project rule\n\nAgent rule")
        XCTAssertEqual(request.messages[1].images.count, 1)
        XCTAssertTrue(request.messages[1].text.contains("note"))
        XCTAssertEqual(request.messages[2].toolCalls.first?.name, "lookup")
        XCTAssertEqual(request.messages[3].role, .tool)
        XCTAssertEqual(request.messages[3].toolResult?.output, "found")
        XCTAssertEqual(request.temperature, 0.3)
    }

    func testMCPFramingToolSelectionAndLocalStdio() async throws {
        let list = MCPSessionPlanner.listToolsRequest(id: 2)
        let encoded = try MCPCodec.encodeStdio(list)
        var buffer = Data(encoded.prefix(8))
        XCTAssertTrue(try MCPCodec.decodeStdio(buffer: &buffer).isEmpty)
        buffer.append(encoded.dropFirst(8))
        let call = MCPSessionPlanner.callToolRequest(id: 3, name: "echo", arguments: .object(["text": .string("hi")]))
        buffer.append(try MCPCodec.encodeStdio(call))
        let decoded = try MCPCodec.decodeStdio(buffer: &buffer)
        XCTAssertEqual(decoded.map(\.method), ["tools/list", "tools/call"])
        XCTAssertTrue(buffer.isEmpty)

        let sse = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"ok\":true}}\n\n".utf8)
        let httpMessage = try MCPCodec.decodeHTTPResponse(contentType: "text/event-stream", body: sse)
        XCTAssertEqual(httpMessage.id, 4)
        XCTAssertEqual(MCPCodec.sessionID(headers: ["Mcp-Session-Id": "abc"]), "abc")

        let echo = MCPTool(name: "echo", description: "Echo", inputSchema: "{\"type\":\"object\"}")
        let write = MCPTool(name: "write", description: "Write", inputSchema: "{\"type\":\"object\"}")
        XCTAssertEqual(ToolCatalog.filtered([echo, write], enabledNames: ["echo"]).map(\.name), ["echo"])
        XCTAssertTrue(ToolCatalog.filtered([echo], enabledNames: []).isEmpty)

        let client = MCPClient(transport: ScriptedMCPTransport(responses: [
            JSONRPCMessage(id: 1, result: .object(["protocolVersion": .string("2024-11-05")])),
            JSONRPCMessage(id: 2, result: .object([
                "tools": .array([
                    .object([
                        "name": .string("echo"),
                        "description": .string("Echo"),
                        "inputSchema": .object(["type": .string("object")]),
                    ]),
                ]),
            ])),
            JSONRPCMessage(id: 3, result: .object([
                "content": .array([.object(["type": .string("text"), "text": .string("pong")])]),
                "isError": .bool(false),
            ])),
        ]))
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let result = try await client.callTool(name: "echo", arguments: .object(["text": .string("hi")]), callID: "call_1")
        XCTAssertEqual(result.output, "pong")
        XCTAssertFalse(result.isError)

        let loop = await ToolLoop.results(drafts: [
            ToolCallDraft(id: "1", name: "echo", arguments: "{}"),
            ToolCallDraft(id: "2", name: "write", arguments: "{}"),
        ], allowed: [echo]) { draft in
            ToolResult(id: draft.id, name: draft.name, arguments: draft.arguments, output: "ok", isError: false)
        }
        XCTAssertEqual(loop.map(\.isError), [false, true])
        XCTAssertFalse(ToolRoundPolicy.shouldContinue(round: 4, toolCalls: [ToolCallDraft(id: "1", name: "echo", arguments: "{}")]))
        XCTAssertTrue(ToolRoundPolicy.shouldContinue(round: 1, toolCalls: [ToolCallDraft(id: "1", name: "echo", arguments: "{}")]))

        try await runStdioStub()
    }

    private func runStdioStub() async throws {
        let script = """
        import sys, json
        def read_message():
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if line in (b"\\r\\n", b"\\n", b""):
                    break
                key, value = line.decode().split(":", 1)
                headers[key.strip().lower()] = value.strip()
            length = int(headers.get("content-length", "0"))
            if length == 0:
                return None
            return json.loads(sys.stdin.buffer.read(length))
        def write_message(payload):
            data = json.dumps(payload).encode()
            sys.stdout.buffer.write(f"Content-Length: {len(data)}\\r\\n\\r\\n".encode() + data)
            sys.stdout.buffer.flush()
        while True:
            message = read_message()
            if not message:
                break
            method = message.get("method")
            identifier = message.get("id")
            if method == "initialize":
                write_message({"jsonrpc":"2.0","id":identifier,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"stub","version":"0"}}})
            elif method == "notifications/initialized":
                continue
            elif method == "tools/list":
                write_message({"jsonrpc":"2.0","id":identifier,"result":{"tools":[{"name":"echo","description":"Echo","inputSchema":{"type":"object"}}]}})
            elif method == "tools/call":
                write_message({"jsonrpc":"2.0","id":identifier,"result":{"content":[{"type":"text","text":"pong"}],"isError":False}})
            elif identifier is not None:
                write_message({"jsonrpc":"2.0","id":identifier,"result":{}})
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-mcp-\(UUID().uuidString).py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        let transport = try MCPStdioTransport(command: "/usr/bin/python3", arguments: [url.path])
        defer { transport.terminate() }
        let client = MCPClient(transport: transport)
        try await client.initialize()
        let tools = try await client.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let result = try await client.callTool(name: "echo", arguments: .object(["text": .string("hi")]), callID: "call_9")
        XCTAssertEqual(result.output, "pong")
    }

    private func sampleRequest(provider: ProviderKind, model: String) -> ChatRequest {
        ChatRequest(
            model: ModelRef(provider: provider, name: model),
            messages: [
                ProviderMessage(role: .system, text: "Be brief."),
                ProviderMessage(
                    role: .user,
                    text: "Look",
                    images: [ProviderImage(mimeType: "image/png", base64: "aGVsbG8=")]
                ),
            ],
            temperature: 0.2,
            tools: [ToolDefinition(name: "lookup", description: "Find a thing", jsonSchema: "{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}}")]
        )
    }
}
