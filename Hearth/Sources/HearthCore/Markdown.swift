import Foundation

public enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case bulletList([String])
    case numberedList([String])
    case quote(String)
    case image(alt: String, source: String)
}

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            paragraph.removeAll()
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
        }

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("```") {
                flushParagraph()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var code: [String] = []
                while index < lines.count && !lines[index].hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }
            if let image = parseImage(line) {
                flushParagraph()
                blocks.append(.image(alt: image.alt, source: image.source))
                index += 1
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph()
                let level = min(line.prefix(while: { $0 == "#" }).count, 6)
                let content = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: String(content)))
                index += 1
                continue
            }
            if line.hasPrefix("> ") || line == ">" {
                flushParagraph()
                var quotes: [String] = []
                while index < lines.count && (lines[index].hasPrefix("> ") || lines[index] == ">") {
                    quotes.append(lines[index] == ">" ? "" : String(lines[index].dropFirst(2)))
                    index += 1
                }
                blocks.append(.quote(quotes.joined(separator: "\n")))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                var items: [String] = []
                while index < lines.count && (lines[index].hasPrefix("- ") || lines[index].hasPrefix("* ")) {
                    items.append(String(lines[index].dropFirst(2)))
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }
            if let number = numberedPrefix(line) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count, let prefix = numberedPrefix(lines[index]) {
                    items.append(String(lines[index].dropFirst(prefix)))
                    index += 1
                }
                blocks.append(.numberedList(items))
                _ = number
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                index += 1
                continue
            }
            paragraph.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func parseImage(_ line: String) -> (alt: String, source: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("![") else { return nil }
        guard let altEnd = trimmed.firstIndex(of: "]"),
              trimmed.index(after: altEnd) < trimmed.endIndex,
              trimmed[trimmed.index(after: altEnd)] == "(" else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd])
        let rest = trimmed[trimmed.index(altEnd, offsetBy: 2)...]
        guard let close = rest.firstIndex(of: ")") else { return nil }
        let source = String(rest[..<close])
        return (alt, source)
    }

    private static func numberedPrefix(_ line: String) -> Int? {
        var digits = 0
        for character in line {
            if character.isNumber {
                digits += 1
            } else {
                break
            }
        }
        guard digits > 0 else { return nil }
        let marker = line.dropFirst(digits)
        guard marker.hasPrefix(". ") else { return nil }
        return digits + 2
    }
}

public struct RichTranscriptItem: Sendable, Equatable {
    public var messageID: UUID
    public var role: MessageRole
    public var blocks: [MarkdownBlock]
    public var reasoning: String
    public var citations: [Citation]
    public var toolCalls: [ToolCallDraft]
    public var toolResults: [ToolResult]
    public var attachmentIDs: [UUID]
    public var status: MessageStatus

    public init(
        messageID: UUID,
        role: MessageRole,
        blocks: [MarkdownBlock],
        reasoning: String,
        citations: [Citation],
        toolCalls: [ToolCallDraft],
        toolResults: [ToolResult],
        attachmentIDs: [UUID],
        status: MessageStatus
    ) {
        self.messageID = messageID
        self.role = role
        self.blocks = blocks
        self.reasoning = reasoning
        self.citations = citations
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.attachmentIDs = attachmentIDs
        self.status = status
    }
}

public enum TranscriptPresenter {
    public static func present(_ message: Message) -> RichTranscriptItem {
        RichTranscriptItem(
            messageID: message.id,
            role: message.role,
            blocks: MarkdownParser.parse(message.text),
            reasoning: message.reasoning,
            citations: message.citations,
            toolCalls: message.toolCalls,
            toolResults: message.toolResults,
            attachmentIDs: message.attachmentIDs,
            status: message.status
        )
    }
}
