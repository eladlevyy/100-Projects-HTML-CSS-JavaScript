import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ProviderImage: Sendable, Equatable {
    public var mimeType: String
    public var base64: String

    public init(mimeType: String, base64: String) {
        self.mimeType = mimeType
        self.base64 = base64
    }
}

public struct ProviderMessage: Sendable, Equatable {
    public var role: MessageRole
    public var text: String
    public var images: [ProviderImage]
    public var toolCalls: [ToolCallDraft]
    public var toolResult: ToolResult?

    public init(
        role: MessageRole,
        text: String,
        images: [ProviderImage] = [],
        toolCalls: [ToolCallDraft] = [],
        toolResult: ToolResult? = nil
    ) {
        self.role = role
        self.text = text
        self.images = images
        self.toolCalls = toolCalls
        self.toolResult = toolResult
    }
}

public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var jsonSchema: String

    public init(name: String, description: String, jsonSchema: String) {
        self.name = name
        self.description = description
        self.jsonSchema = jsonSchema
    }
}

public struct ChatRequest: Sendable, Equatable {
    public var model: ModelRef
    public var messages: [ProviderMessage]
    public var temperature: Double?
    public var tools: [ToolDefinition]
    public var stream: Bool

    public init(
        model: ModelRef,
        messages: [ProviderMessage],
        temperature: Double? = nil,
        tools: [ToolDefinition] = [],
        stream: Bool = true
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.tools = tools
        self.stream = stream
    }
}

public struct ProviderCredentials: Sendable, Equatable {
    public var openAIKey: String?
    public var anthropicKey: String?
    public var geminiKey: String?
    public var ollamaBaseURL: URL

    public init(
        openAIKey: String? = nil,
        anthropicKey: String? = nil,
        geminiKey: String? = nil,
        ollamaBaseURL: URL = URL(string: "http://127.0.0.1:11434")!
    ) {
        self.openAIKey = openAIKey
        self.anthropicKey = anthropicKey
        self.geminiKey = geminiKey
        self.ollamaBaseURL = ollamaBaseURL
    }
}

public struct ProviderHTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, method: String, headers: [String: String], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    public func jsonBody() throws -> JSONValue {
        try JSONValue.parse(body)
    }
}

public enum PromptAssembly {
    public static func request(
        chat: Chat,
        project: Project?,
        agent: Agent?,
        messages: [Message],
        attachments: [Attachment],
        attachmentBytes: [UUID: Data],
        tools: [ToolDefinition],
        model: ModelRef? = nil
    ) -> ChatRequest {
        var providerMessages: [ProviderMessage] = []
        var systemParts: [String] = []
        if let instructions = project?.instructions, !instructions.isEmpty {
            systemParts.append(instructions)
        }
        if let prompt = agent?.systemPrompt, !prompt.isEmpty {
            systemParts.append(prompt)
        }
        if !systemParts.isEmpty {
            providerMessages.append(ProviderMessage(role: .system, text: systemParts.joined(separator: "\n\n")))
        }
        let attachmentLookup = Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0) })
        for message in messages where message.role != .system {
            var text = message.text
            var images: [ProviderImage] = []
            for id in message.attachmentIDs {
                guard let attachment = attachmentLookup[id], let bytes = attachmentBytes[id] else { continue }
                if attachment.isImage {
                    images.append(ProviderImage(mimeType: attachment.mimeType, base64: bytes.base64EncodedString()))
                } else if let utf8 = String(data: bytes, encoding: .utf8) {
                    text += "\n\nFile \(attachment.filename):\n\(utf8)"
                } else {
                    text += "\n\nFile \(attachment.filename) is binary and was not inlined."
                }
            }
            var toolResult: ToolResult?
            if message.role == .tool, let first = message.toolResults.first {
                toolResult = first
            }
            providerMessages.append(
                ProviderMessage(
                    role: message.role,
                    text: text,
                    images: images,
                    toolCalls: message.toolCalls,
                    toolResult: toolResult
                )
            )
            if message.role == .assistant {
                for result in message.toolResults {
                    providerMessages.append(
                        ProviderMessage(role: .tool, text: result.output, toolResult: result)
                    )
                }
            }
        }
        return ChatRequest(
            model: model ?? agent?.model ?? chat.model,
            messages: providerMessages,
            temperature: agent?.temperature,
            tools: tools,
            stream: true
        )
    }
}

public enum ProviderTranslator {
    public static func makeRequest(chat: ChatRequest, credentials: ProviderCredentials) throws -> ProviderHTTPRequest {
        switch chat.model.provider {
        case .openAI:
            guard let key = credentials.openAIKey, !key.isEmpty else {
                throw ProviderFailure.unauthorized(message: "Add an OpenAI API key in Settings.")
            }
            let body = try openAIBody(chat).encoded()
            return ProviderHTTPRequest(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                method: "POST",
                headers: [
                    "Authorization": "Bearer \(key)",
                    "Content-Type": "application/json",
                ],
                body: body
            )
        case .anthropic:
            guard let key = credentials.anthropicKey, !key.isEmpty else {
                throw ProviderFailure.unauthorized(message: "Add an Anthropic API key in Settings.")
            }
            let body = try anthropicBody(chat).encoded()
            return ProviderHTTPRequest(
                url: URL(string: "https://api.anthropic.com/v1/messages")!,
                method: "POST",
                headers: [
                    "x-api-key": key,
                    "anthropic-version": "2023-06-01",
                    "Content-Type": "application/json",
                ],
                body: body
            )
        case .gemini:
            guard let key = credentials.geminiKey, !key.isEmpty else {
                throw ProviderFailure.unauthorized(message: "Add a Google Gemini API key in Settings.")
            }
            let encodedModel = chat.model.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chat.model.name
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):streamGenerateContent")
            components?.queryItems = [
                URLQueryItem(name: "alt", value: "sse"),
                URLQueryItem(name: "key", value: key),
            ]
            guard let url = components?.url else {
                throw ProviderFailure.malformed(message: "Could not build the Gemini request URL.")
            }
            let body = try geminiBody(chat).encoded()
            return ProviderHTTPRequest(
                url: url,
                method: "POST",
                headers: ["Content-Type": "application/json"],
                body: body
            )
        case .ollama:
            let body = try ollamaBody(chat).encoded()
            return ProviderHTTPRequest(
                url: ollamaChatURL(credentials.ollamaBaseURL),
                method: "POST",
                headers: ["Content-Type": "application/json"],
                body: body
            )
        }
    }

    public static func decodeFailure(
        provider: ProviderKind,
        status: Int,
        headers: [String: String],
        body: Data
    ) -> ProviderFailure {
        let message = errorMessage(provider: provider, body: body) ?? "Provider request failed."
        let retryAfter = retryAfterSeconds(headers)
        if status == 429 {
            return .rateLimited(retryAfterSeconds: retryAfter, message: message)
        }
        if status == 401 || status == 403 {
            return .unauthorized(message: message)
        }
        return .server(status: status, message: message)
    }

    public static func ollamaChatURL(_ base: URL) -> URL {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + "/api/chat") ?? base
    }

    private static func openAIBody(_ chat: ChatRequest) -> JSONValue {
        var payload: [String: JSONValue] = [
            "model": .string(chat.model.name),
            "stream": .bool(chat.stream),
            "messages": .array(chat.messages.map(openAIMessage)),
        ]
        if let temperature = chat.temperature {
            payload["temperature"] = .number(temperature)
        }
        if !chat.tools.isEmpty {
            payload["tools"] = .array(chat.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": schemaValue(tool.jsonSchema),
                    ]),
                ])
            })
        }
        return .object(payload)
    }

    private static func openAIMessage(_ message: ProviderMessage) -> JSONValue {
        let role = message.role == .tool ? "tool" : message.role.rawValue
        var payload: [String: JSONValue] = ["role": .string(role)]
        if message.images.isEmpty {
            payload["content"] = .string(message.text)
        } else {
            var parts: [JSONValue] = []
            if !message.text.isEmpty {
                parts.append(.object(["type": .string("text"), "text": .string(message.text)]))
            }
            for image in message.images {
                parts.append(.object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string("data:\(image.mimeType);base64,\(image.base64)"),
                    ]),
                ]))
            }
            payload["content"] = .array(parts)
        }
        if !message.toolCalls.isEmpty {
            payload["tool_calls"] = .array(message.toolCalls.map { call in
                .object([
                    "id": .string(call.id),
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(call.name),
                        "arguments": .string(call.arguments),
                    ]),
                ])
            })
        }
        if let result = message.toolResult, message.role == .tool {
            payload["tool_call_id"] = .string(result.id)
            payload["content"] = .string(result.output)
        }
        return .object(payload)
    }

    private static func anthropicBody(_ chat: ChatRequest) -> JSONValue {
        let system = chat.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        let messages = chat.messages.filter { $0.role != .system }
        var payload: [String: JSONValue] = [
            "model": .string(chat.model.name),
            "max_tokens": .number(8192),
            "stream": .bool(chat.stream),
            "messages": .array(messages.map(anthropicMessage)),
        ]
        if !system.isEmpty {
            payload["system"] = .string(system)
        }
        if let temperature = chat.temperature {
            payload["temperature"] = .number(temperature)
        }
        if !chat.tools.isEmpty {
            payload["tools"] = .array(chat.tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": schemaValue(tool.jsonSchema),
                ])
            })
        }
        return .object(payload)
    }

    private static func anthropicMessage(_ message: ProviderMessage) -> JSONValue {
        let role = message.role == .assistant ? "assistant" : "user"
        var blocks: [JSONValue] = []
        if message.role == .tool, let result = message.toolResult {
            blocks.append(.object([
                "type": .string("tool_result"),
                "tool_use_id": .string(result.id),
                "content": .string(result.output),
                "is_error": .bool(result.isError),
            ]))
        } else {
            if !message.text.isEmpty {
                blocks.append(.object(["type": .string("text"), "text": .string(message.text)]))
            }
            for image in message.images {
                blocks.append(.object([
                    "type": .string("image"),
                    "source": .object([
                        "type": .string("base64"),
                        "media_type": .string(image.mimeType),
                        "data": .string(image.base64),
                    ]),
                ]))
            }
            for call in message.toolCalls {
                blocks.append(.object([
                    "type": .string("tool_use"),
                    "id": .string(call.id),
                    "name": .string(call.name),
                    "input": schemaValue(call.arguments.isEmpty ? "{}" : call.arguments),
                ]))
            }
        }
        if blocks.isEmpty {
            blocks.append(.object(["type": .string("text"), "text": .string("")]))
        }
        return .object(["role": .string(role), "content": .array(blocks)])
    }

    private static func geminiBody(_ chat: ChatRequest) -> JSONValue {
        let system = chat.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
        var payload: [String: JSONValue] = [
            "contents": .array(chat.messages.filter { $0.role != .system }.map(geminiContent)),
        ]
        if !system.isEmpty {
            payload["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(system)])]),
            ])
        }
        if let temperature = chat.temperature {
            payload["generationConfig"] = .object(["temperature": .number(temperature)])
        }
        if !chat.tools.isEmpty {
            payload["tools"] = .array([
                .object([
                    "functionDeclarations": .array(chat.tools.map { tool in
                        .object([
                            "name": .string(tool.name),
                            "description": .string(tool.description),
                            "parameters": schemaValue(tool.jsonSchema),
                        ])
                    }),
                ]),
            ])
        }
        return .object(payload)
    }

    private static func geminiContent(_ message: ProviderMessage) -> JSONValue {
        let role = message.role == .assistant ? "model" : "user"
        var parts: [JSONValue] = []
        if let result = message.toolResult, message.role == .tool {
            parts.append(.object([
                "functionResponse": .object([
                    "name": .string(result.name),
                    "response": .object(["output": .string(result.output)]),
                ]),
            ]))
        } else {
            if !message.text.isEmpty {
                parts.append(.object(["text": .string(message.text)]))
            }
            for image in message.images {
                parts.append(.object([
                    "inlineData": .object([
                        "mimeType": .string(image.mimeType),
                        "data": .string(image.base64),
                    ]),
                ]))
            }
            for call in message.toolCalls {
                parts.append(.object([
                    "functionCall": .object([
                        "name": .string(call.name),
                        "args": schemaValue(call.arguments.isEmpty ? "{}" : call.arguments),
                    ]),
                ]))
            }
        }
        if parts.isEmpty {
            parts.append(.object(["text": .string("")]))
        }
        return .object(["role": .string(role), "parts": .array(parts)])
    }

    private static func ollamaBody(_ chat: ChatRequest) -> JSONValue {
        var payload: [String: JSONValue] = [
            "model": .string(chat.model.name),
            "stream": .bool(chat.stream),
            "messages": .array(chat.messages.map(ollamaMessage)),
        ]
        if let temperature = chat.temperature {
            payload["options"] = .object(["temperature": .number(temperature)])
        }
        if !chat.tools.isEmpty {
            payload["tools"] = .array(chat.tools.map { tool in
                .object([
                    "type": .string("function"),
                    "function": .object([
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": schemaValue(tool.jsonSchema),
                    ]),
                ])
            })
        }
        return .object(payload)
    }

    private static func ollamaMessage(_ message: ProviderMessage) -> JSONValue {
        var payload: [String: JSONValue] = [
            "role": .string(message.role.rawValue),
            "content": .string(message.role == .tool ? (message.toolResult?.output ?? message.text) : message.text),
        ]
        if !message.images.isEmpty {
            payload["images"] = .array(message.images.map { .string($0.base64) })
        }
        return .object(payload)
    }

    private static func schemaValue(_ json: String) -> JSONValue {
        if let value = try? JSONValue.parse(Data(json.utf8)), value.objectValue != nil {
            return value
        }
        return .object(["type": .string("object")])
    }

    private static func errorMessage(provider: ProviderKind, body: Data) -> String? {
        guard let json = try? JSONValue.parse(body) else {
            let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        switch provider {
        case .openAI, .gemini:
            return json["error"]?["message"]?.stringValue
        case .anthropic:
            return json["error"]?["message"]?.stringValue
        case .ollama:
            return json["error"]?.stringValue
        }
    }

    private static func retryAfterSeconds(_ headers: [String: String]) -> Double? {
        let value = headers.first { $0.key.lowercased() == "retry-after" }?.value
        return value.flatMap(Double.init)
    }
}

public struct ProviderStreamDecoder: Sendable {
    public var provider: ProviderKind
    public var eventName: String?
    public var toolIDsByIndex: [Int: String]

    public init(provider: ProviderKind) {
        self.provider = provider
        self.eventName = nil
        self.toolIDsByIndex = [:]
    }

    public mutating func decode(_ line: String) -> [StreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        if provider == .ollama {
            return decodeOllama(trimmed)
        }
        if trimmed.hasPrefix("event:") {
            eventName = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return []
        }
        guard trimmed.hasPrefix("data:") else { return [] }
        let data = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        switch provider {
        case .openAI:
            return decodeOpenAI(String(data))
        case .anthropic:
            return decodeAnthropic(event: eventName, data: String(data))
        case .gemini:
            return decodeGemini(String(data))
        case .ollama:
            return []
        }
    }

    private mutating func decodeOpenAI(_ data: String) -> [StreamEvent] {
        if data == "[DONE]" {
            return [.completed(finishReason: "stop")]
        }
        guard let json = try? JSONValue.parse(Data(data.utf8)) else {
            return [.failed(.malformed(message: "Could not read an OpenAI event."))]
        }
        if let error = json["error"] {
            let message = error["message"]?.stringValue ?? "OpenAI request failed."
            let code = error["code"]?.stringValue ?? ""
            if code.contains("rate_limit") || message.lowercased().contains("rate limit") {
                return [.failed(.rateLimited(retryAfterSeconds: nil, message: message))]
            }
            return [.failed(.server(status: 400, message: message))]
        }
        guard let choice = json["choices"]?.arrayValue?.first else { return [] }
        let delta = choice["delta"]
        var events: [StreamEvent] = []
        if let content = delta?["content"]?.stringValue, !content.isEmpty {
            events.append(.text(content))
        }
        let reasoning = delta?["reasoning_content"]?.stringValue ?? delta?["reasoning"]?.stringValue
        if let reasoning, !reasoning.isEmpty {
            events.append(.reasoning(reasoning))
        }
        if let calls = delta?["tool_calls"]?.arrayValue {
            for call in calls {
                let index = call["index"]?.intValue ?? 0
                if let explicitID = call["id"]?.stringValue {
                    toolIDsByIndex[index] = explicitID
                }
                let id = call["id"]?.stringValue ?? toolIDsByIndex[index] ?? "index-\(index)"
                let name = call["function"]?["name"]?.stringValue
                let arguments = call["function"]?["arguments"]?.stringValue ?? ""
                events.append(.toolCallDelta(id: id, name: name, argumentsDelta: arguments))
            }
        }
        let annotations = delta?["annotations"]?.arrayValue ?? choice["message"]?["annotations"]?.arrayValue ?? []
        for annotation in annotations {
            let urlCitation = annotation["url_citation"]
            let url = urlCitation?["url"]?.stringValue ?? annotation["url"]?.stringValue
            let title = urlCitation?["title"]?.stringValue ?? annotation["title"]?.stringValue
            let snippet = urlCitation?["snippet"]?.stringValue
            events.append(.citation(Citation(title: title, url: url, snippet: snippet)))
        }
        if let finish = choice["finish_reason"]?.stringValue {
            events.append(.completed(finishReason: finish))
        }
        return events
    }

    private mutating func decodeAnthropic(event: String?, data: String) -> [StreamEvent] {
        guard let json = try? JSONValue.parse(Data(data.utf8)) else {
            return [.failed(.malformed(message: "Could not read an Anthropic event."))]
        }
        let type = event ?? json["type"]?.stringValue
        switch type {
        case "content_block_start":
            let block = json["content_block"]
            let index = json["index"]?.intValue ?? 0
            if block?["type"]?.stringValue == "tool_use" {
                let id = block?["id"]?.stringValue ?? "tool-\(index)"
                toolIDsByIndex[index] = id
                return [.toolCallDelta(id: id, name: block?["name"]?.stringValue, argumentsDelta: "")]
            }
            return []
        case "content_block_delta":
            let delta = json["delta"]
            switch delta?["type"]?.stringValue {
            case "text_delta":
                let text = delta?["text"]?.stringValue ?? ""
                return text.isEmpty ? [] : [.text(text)]
            case "thinking_delta":
                let text = delta?["thinking"]?.stringValue ?? ""
                return text.isEmpty ? [] : [.reasoning(text)]
            case "citations_delta":
                let citation = delta?["citation"]
                return [.citation(Citation(
                    title: citation?["title"]?.stringValue ?? citation?["document_title"]?.stringValue,
                    url: citation?["url"]?.stringValue,
                    snippet: citation?["cited_text"]?.stringValue
                ))]
            case "input_json_delta":
                let index = json["index"]?.intValue ?? 0
                let id = toolIDsByIndex[index] ?? "block-\(index)"
                return [.toolCallDelta(id: id, name: nil, argumentsDelta: delta?["partial_json"]?.stringValue ?? "")]
            default:
                return []
            }
        case "message_stop":
            return [.completed(finishReason: "stop")]
        case "error":
            let message = json["error"]?["message"]?.stringValue ?? "Anthropic request failed."
            let errType = json["error"]?["type"]?.stringValue ?? ""
            if errType.contains("rate_limit") {
                return [.failed(.rateLimited(retryAfterSeconds: nil, message: message))]
            }
            return [.failed(.server(status: 400, message: message))]
        default:
            return []
        }
    }

    private func decodeGemini(_ data: String) -> [StreamEvent] {
        guard let json = try? JSONValue.parse(Data(data.utf8)) else {
            return [.failed(.malformed(message: "Could not read a Gemini event."))]
        }
        if let message = json["error"]?["message"]?.stringValue {
            let status = json["error"]?["status"]?.stringValue ?? ""
            if status == "RESOURCE_EXHAUSTED" {
                return [.failed(.rateLimited(retryAfterSeconds: nil, message: message))]
            }
            return [.failed(.server(status: 400, message: message))]
        }
        guard let candidate = json["candidates"]?.arrayValue?.first else { return [] }
        var events: [StreamEvent] = []
        for part in candidate["content"]?["parts"]?.arrayValue ?? [] {
            let thought = part["thought"]?.boolValue == true
            if let text = part["text"]?.stringValue, !text.isEmpty {
                events.append(thought ? .reasoning(text) : .text(text))
            }
            if let call = part["functionCall"] {
                let name = call["name"]?.stringValue ?? "tool"
                let args = (try? call["args"]?.encoded()) ?? Data("{}".utf8)
                events.append(.toolCallDelta(
                    id: "gemini-\(name)",
                    name: name,
                    argumentsDelta: String(decoding: args, as: UTF8.self)
                ))
            }
        }
        if let citation = candidate["citationMetadata"]?["citationSources"]?.arrayValue {
            for source in citation {
                events.append(.citation(Citation(
                    title: source["title"]?.stringValue,
                    url: source["uri"]?.stringValue,
                    snippet: nil
                )))
            }
        }
        if let finish = candidate["finishReason"]?.stringValue {
            events.append(.completed(finishReason: finish))
        }
        return events
    }

    private func decodeOllama(_ line: String) -> [StreamEvent] {
        guard let json = try? JSONValue.parse(Data(line.utf8)) else {
            return [.failed(.malformed(message: "Could not read an Ollama event."))]
        }
        if let error = json["error"]?.stringValue {
            return [.failed(.server(status: 500, message: error))]
        }
        var events: [StreamEvent] = []
        if let thinking = json["message"]?["thinking"]?.stringValue, !thinking.isEmpty {
            events.append(.reasoning(thinking))
        }
        if let content = json["message"]?["content"]?.stringValue, !content.isEmpty {
            events.append(.text(content))
        }
        if let calls = json["message"]?["tool_calls"]?.arrayValue {
            for call in calls {
                let function = call["function"]
                let name = function?["name"]?.stringValue ?? "tool"
                let args = (try? function?["arguments"]?.encoded()) ?? Data("{}".utf8)
                events.append(.toolCallDelta(
                    id: "ollama-\(name)",
                    name: name,
                    argumentsDelta: String(decoding: args, as: UTF8.self)
                ))
            }
        }
        if json["done"]?.boolValue == true {
            events.append(.completed(finishReason: "stop"))
        }
        return events
    }
}

public protocol StreamingHTTPClient: Sendable {
    func lines(for request: ProviderHTTPRequest, provider: ProviderKind) -> AsyncThrowingStream<String, Error>
}

public struct ScriptedStreamingClient: StreamingHTTPClient {
    public var lines: [String]
    public var failureAfter: Int?
    public var failure: ProviderFailure?

    public init(lines: [String], failureAfter: Int? = nil, failure: ProviderFailure? = nil) {
        self.lines = lines
        self.failureAfter = failureAfter
        self.failure = failure
    }

    public func lines(for request: ProviderHTTPRequest, provider: ProviderKind) -> AsyncThrowingStream<String, Error> {
        let lines = self.lines
        let failureAfter = self.failureAfter
        let failure = self.failure
        return AsyncThrowingStream { continuation in
            let task = Task {
                var index = 0
                for line in lines {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    if let failureAfter, index == failureAfter, let failure {
                        continuation.finish(throwing: failure)
                        return
                    }
                    continuation.yield(line)
                    index += 1
                }
                if let failure, failureAfter == nil {
                    continuation.finish(throwing: failure)
                    return
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

public enum ChatTurnRunner {
    public static func run(
        request: ChatRequest,
        credentials: ProviderCredentials,
        client: any StreamingHTTPClient,
        onSnapshot: (@Sendable (StreamSnapshot) -> Void)? = nil
    ) async -> StreamSnapshot {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var lastEmitMS = -1_000.0
        func publish(_ snapshot: StreamSnapshot, force: Bool) {
            let now = milliseconds(since: startedAt, clock: clock)
            guard force || now - lastEmitMS >= 33 else { return }
            lastEmitMS = now
            onSnapshot?(snapshot)
        }

        var snapshot = StreamSnapshot()
        let http: ProviderHTTPRequest
        do {
            http = try ProviderTranslator.makeRequest(chat: request, credentials: credentials)
        } catch let failure as ProviderFailure {
            snapshot = StreamingReducer.reduce(snapshot, .failed(failure))
            publish(snapshot, force: true)
            return snapshot
        } catch {
            snapshot = StreamingReducer.reduce(snapshot, .failed(.malformed(message: "Could not build the provider request.")))
            publish(snapshot, force: true)
            return snapshot
        }
        snapshot = StreamingReducer.reduce(snapshot, .started)
        publish(snapshot, force: true)
        var decoder = ProviderStreamDecoder(provider: request.model.provider)
        let stream = client.lines(for: http, provider: request.model.provider)
        do {
            for try await line in stream {
                if Task.isCancelled {
                    snapshot = StreamingReducer.reduce(snapshot, .cancelled)
                    publish(snapshot, force: true)
                    return snapshot
                }
                for event in decoder.decode(line) {
                    snapshot = StreamingReducer.reduce(snapshot, event)
                    if isTerminal(snapshot.phase) {
                        publish(snapshot, force: true)
                        return snapshot
                    }
                    publish(snapshot, force: false)
                }
            }
        } catch is CancellationError {
            snapshot = StreamingReducer.reduce(snapshot, .cancelled)
            publish(snapshot, force: true)
            return snapshot
        } catch let failure as ProviderFailure {
            snapshot = StreamingReducer.reduce(snapshot, .failed(failure))
            publish(snapshot, force: true)
            return snapshot
        } catch let error as URLError where error.code == .cancelled {
            snapshot = StreamingReducer.reduce(snapshot, .cancelled)
            publish(snapshot, force: true)
            return snapshot
        } catch {
            snapshot = StreamingReducer.reduce(snapshot, .failed(.network(message: "The provider connection failed.")))
            publish(snapshot, force: true)
            return snapshot
        }
        if snapshot.phase == .streaming {
            snapshot = StreamingReducer.reduce(snapshot, .interrupted)
        }
        publish(snapshot, force: true)
        return snapshot
    }

    private static func milliseconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
        let elapsed = start.duration(to: clock.now)
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func isTerminal(_ phase: StreamPhase) -> Bool {
        switch phase {
        case .idle, .streaming:
            return false
        case .completed, .cancelled, .failed, .interrupted:
            return true
        }
    }
}

public enum ToolRoundPolicy {
    public static let maxRounds = 4

    public static func shouldContinue(round: Int, toolCalls: [ToolCallDraft]) -> Bool {
        round < maxRounds && toolCalls.contains { !$0.name.isEmpty }
    }
}

public enum ToolCatalog {
    public static func definitions(from tools: [MCPTool]) -> [ToolDefinition] {
        tools.map { ToolDefinition(name: $0.name, description: $0.description, jsonSchema: $0.inputSchema) }
    }

    public static func filtered(_ tools: [MCPTool], enabledNames: [String]) -> [MCPTool] {
        let allowed = Set(enabledNames)
        return tools.filter { allowed.contains($0.name) }
    }
}
