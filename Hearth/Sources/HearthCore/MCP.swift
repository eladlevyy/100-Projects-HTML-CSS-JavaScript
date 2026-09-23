import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MCPTool: Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var inputSchema: String

    public var id: String { name }

    public init(name: String, description: String, inputSchema: String) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct JSONRPCMessage: Sendable, Equatable, Codable {
    public var jsonrpc: String
    public var id: Int?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: JSONValue?

    public init(
        jsonrpc: String = "2.0",
        id: Int? = nil,
        method: String? = nil,
        params: JSONValue? = nil,
        result: JSONValue? = nil,
        error: JSONValue? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

public enum MCPError: Error, Sendable, Equatable {
    case timeout
    case disconnected
    case invalidResponse
    case server(String)
    case toolFailed(String)
}

public enum MCPCodec {
    public static func encodeStdio(_ message: JSONRPCMessage) throws -> Data {
        let body = try JSONEncoder().encode(message)
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    public static func decodeStdio(buffer: inout Data) throws -> [JSONRPCMessage] {
        var messages: [JSONRPCMessage] = []
        while true {
            guard let headerEnd = rangeOfHeaderEnd(buffer) else { break }
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let header = String(data: headerData, encoding: .utf8) else {
                throw MCPError.invalidResponse
            }
            let length = contentLength(header)
            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { break }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)
            messages.append(try JSONDecoder().decode(JSONRPCMessage.self, from: body))
        }
        return messages
    }

    public static func encodeHTTPBody(_ message: JSONRPCMessage) throws -> Data {
        try JSONEncoder().encode(message)
    }

    public static func httpHeaders(sessionID: String?) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ]
        if let sessionID, !sessionID.isEmpty {
            headers["Mcp-Session-Id"] = sessionID
        }
        return headers
    }

    public static func sessionID(headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == "mcp-session-id" }?.value
    }

    public static func decodeHTTPResponse(contentType: String, body: Data) throws -> JSONRPCMessage {
        if contentType.lowercased().contains("text/event-stream") {
            let text = String(decoding: body, as: UTF8.self)
            let dataLines = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let value = String(line)
                guard value.hasPrefix("data:") else { return nil }
                return value.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
            guard let last = dataLines.last, let data = last.data(using: .utf8) else {
                throw MCPError.invalidResponse
            }
            return try JSONDecoder().decode(JSONRPCMessage.self, from: data)
        }
        return try JSONDecoder().decode(JSONRPCMessage.self, from: body)
    }

    private static func contentLength(_ header: String) -> Int {
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 && parts[0].lowercased() == "content-length", let value = Int(parts[1]) {
                return value
            }
        }
        return 0
    }

    private static func rangeOfHeaderEnd(_ data: Data) -> Range<Data.Index>? {
        let pattern = Data([13, 10, 13, 10])
        guard let range = data.range(of: pattern) else { return nil }
        return range
    }
}

public enum MCPSessionPlanner {
    public static let protocolVersion = "2024-11-05"

    public static func initializeRequest(id: Int) -> JSONRPCMessage {
        JSONRPCMessage(
            id: id,
            method: "initialize",
            params: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("Hearth"),
                    "version": .string("1.0.0"),
                ]),
            ])
        )
    }

    public static func initializedNotification() -> JSONRPCMessage {
        JSONRPCMessage(method: "notifications/initialized")
    }

    public static func listToolsRequest(id: Int) -> JSONRPCMessage {
        JSONRPCMessage(id: id, method: "tools/list", params: .object([:]))
    }

    public static func callToolRequest(id: Int, name: String, arguments: JSONValue) -> JSONRPCMessage {
        JSONRPCMessage(
            id: id,
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": arguments,
            ])
        )
    }

    public static func tools(from result: JSONValue) -> [MCPTool] {
        (result["tools"]?.arrayValue ?? []).compactMap { item in
            guard let name = item["name"]?.stringValue else { return nil }
            let schema = (try? item["inputSchema"]?.encoded()) ?? Data("{\"type\":\"object\"}".utf8)
            return MCPTool(
                name: name,
                description: item["description"]?.stringValue ?? "",
                inputSchema: String(decoding: schema, as: UTF8.self)
            )
        }
    }

    public static func toolResult(id: String, name: String, arguments: String, message: JSONRPCMessage) -> ToolResult {
        if let error = message.error {
            let text = error["message"]?.stringValue ?? "Tool call failed."
            return ToolResult(id: id, name: name, arguments: arguments, output: text, isError: true)
        }
        let result = message.result
        let isError = result?["isError"]?.boolValue ?? false
        let content = result?["content"]?.arrayValue ?? []
        let text = content.compactMap { block -> String? in
            if block["type"]?.stringValue == "text" {
                return block["text"]?.stringValue
            }
            return nil
        }.joined(separator: "\n")
        return ToolResult(id: id, name: name, arguments: arguments, output: text, isError: isError)
    }
}

public protocol MCPTransport: Sendable {
    func send(_ message: JSONRPCMessage) async throws -> JSONRPCMessage?
}

public struct ScriptedMCPTransport: MCPTransport {
    public var responses: [JSONRPCMessage]

    public init(responses: [JSONRPCMessage]) {
        self.responses = responses
    }

    public func send(_ message: JSONRPCMessage) async throws -> JSONRPCMessage? {
        if message.id == nil { return nil }
        if let match = responses.first(where: { $0.id == message.id }) {
            return match
        }
        return responses.first
    }
}

public struct MCPClient: Sendable {
    private let transport: any MCPTransport

    public init(transport: any MCPTransport) {
        self.transport = transport
    }

    public func initialize() async throws {
        let response = try await transport.send(MCPSessionPlanner.initializeRequest(id: 1))
        if let error = response?.error {
            throw MCPError.server(error["message"]?.stringValue ?? "Initialize failed.")
        }
        _ = try await transport.send(MCPSessionPlanner.initializedNotification())
    }

    public func listTools() async throws -> [MCPTool] {
        let response = try await transport.send(MCPSessionPlanner.listToolsRequest(id: 2))
        guard let result = response?.result else {
            throw MCPError.invalidResponse
        }
        return MCPSessionPlanner.tools(from: result)
    }

    public func callTool(name: String, arguments: JSONValue, callID: String) async throws -> ToolResult {
        let response = try await transport.send(
            MCPSessionPlanner.callToolRequest(id: 3, name: name, arguments: arguments)
        )
        guard let response else { throw MCPError.invalidResponse }
        let encoded = (try? arguments.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return MCPSessionPlanner.toolResult(id: callID, name: name, arguments: encoded, message: response)
    }
}

public enum ToolLoop {
    public static func results(
        drafts: [ToolCallDraft],
        allowed: [MCPTool],
        invoke: (ToolCallDraft) async throws -> ToolResult
    ) async -> [ToolResult] {
        var output: [ToolResult] = []
        let allowedNames = Set(allowed.map(\.name))
        for draft in drafts where !draft.name.isEmpty {
            if !allowedNames.contains(draft.name) {
                output.append(ToolResult(
                    id: draft.id,
                    name: draft.name,
                    arguments: draft.arguments,
                    output: "Tool \(draft.name) is not enabled for this agent.",
                    isError: true
                ))
                continue
            }
            do {
                output.append(try await invoke(draft))
            } catch {
                output.append(ToolResult(
                    id: draft.id,
                    name: draft.name,
                    arguments: draft.arguments,
                    output: "Tool \(draft.name) failed.",
                    isError: true
                ))
            }
        }
        return output
    }
}

public final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [Int: CheckedContinuation<JSONRPCMessage, Error>] = [:]

    public init(command: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        self.process = process
        self.input = input
        self.output = output
        try process.run()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.receive(data)
        }
    }

    public func send(_ message: JSONRPCMessage) async throws -> JSONRPCMessage? {
        let outbound = message
        let data = try MCPCodec.encodeStdio(outbound)
        if let id = outbound.id {
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                waiters[id] = continuation
                lock.unlock()
                do {
                    try self.input.fileHandleForWriting.write(contentsOf: data)
                } catch {
                    self.lock.lock()
                    self.waiters[id] = nil
                    self.lock.unlock()
                    continuation.resume(throwing: error)
                }
            }
        }
        try input.fileHandleForWriting.write(contentsOf: data)
        return nil
    }

    public func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        process.terminate()
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending.values {
            waiter.resume(throwing: MCPError.disconnected)
        }
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let messages: [JSONRPCMessage]
        do {
            messages = try MCPCodec.decodeStdio(buffer: &buffer)
        } catch {
            lock.unlock()
            return
        }
        var delivered: [(CheckedContinuation<JSONRPCMessage, Error>, JSONRPCMessage)] = []
        for message in messages {
            if let id = message.id, let waiter = waiters.removeValue(forKey: id) {
                delivered.append((waiter, message))
            }
        }
        lock.unlock()
        for (waiter, message) in delivered {
            waiter.resume(returning: message)
        }
    }

    deinit {
        terminate()
    }
}

public struct MCPHTTPTransport: MCPTransport {
    public var url: URL
    public var sessionID: String?
    private let session: URLSession

    public init(url: URL, sessionID: String? = nil, session: URLSession = .shared) {
        self.url = url
        self.sessionID = sessionID
        self.session = session
    }

    public func send(_ message: JSONRPCMessage) async throws -> JSONRPCMessage? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let headers = MCPCodec.httpHeaders(sessionID: sessionID)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try MCPCodec.encodeHTTPBody(message)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.invalidResponse
        }
        if message.id == nil {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.server("Remote MCP server returned \(http.statusCode).")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        return try MCPCodec.decodeHTTPResponse(contentType: contentType, body: data)
    }
}
