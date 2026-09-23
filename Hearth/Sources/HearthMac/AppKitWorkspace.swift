#if os(macOS)
import AppKit
import SwiftUI
import HearthCore

extension Notification.Name {
    static let hearthSubmitComposer = Notification.Name("HearthSubmitComposer")
}

enum HearthTheme {
    static let paper = NSColor(srgbRed: 0.957, green: 0.945, blue: 0.918, alpha: 1)
    static let sidebar = NSColor(srgbRed: 0.906, green: 0.882, blue: 0.839, alpha: 1)
    static let ink = NSColor(srgbRed: 0.110, green: 0.098, blue: 0.082, alpha: 1)
    static let accent = NSColor(srgbRed: 0.059, green: 0.431, blue: 0.337, alpha: 1)
    static let code = NSColor(srgbRed: 0.118, green: 0.106, blue: 0.094, alpha: 1)
    static let codeText = NSColor(srgbRed: 0.953, green: 0.929, blue: 0.894, alpha: 1)
}

enum MarkdownDrawing {
    static func attributed(_ message: Message, width: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: 13)
        let ink = HearthTheme.ink
        if !message.reasoning.isEmpty {
            append(result, "Reasoning\n", font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: HearthTheme.accent)
            append(result, message.reasoning + "\n\n", font: NSFont.systemFont(ofSize: 12), color: ink.withAlphaComponent(0.75))
        }
        for block in MarkdownParser.parse(message.text) {
            switch block {
            case .heading(let level, let text):
                append(result, text + "\n", font: NSFont.systemFont(ofSize: level == 1 ? 20 : 16, weight: .semibold), color: ink)
            case .paragraph(let text):
                append(result, text + "\n\n", font: body, color: ink)
            case .code(_, let code):
                append(result, code + "\n\n", font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), color: HearthTheme.codeText, background: HearthTheme.code)
            case .bulletList(let items):
                for item in items { append(result, "• \(item)\n", font: body, color: ink) }
                append(result, "\n", font: body, color: ink)
            case .numberedList(let items):
                for (index, item) in items.enumerated() { append(result, "\(index + 1). \(item)\n", font: body, color: ink) }
                append(result, "\n", font: body, color: ink)
            case .quote(let text):
                append(result, text + "\n\n", font: NSFont.systemFont(ofSize: 13, weight: .medium), color: ink.withAlphaComponent(0.8))
            case .image(let alt, let source):
                append(result, "Image: \(alt.isEmpty ? source : alt)\n\n", font: body, color: HearthTheme.accent)
            }
        }
        if !message.citations.isEmpty {
            append(result, "Citations\n", font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: HearthTheme.accent)
            for citation in message.citations {
                let line = [citation.title, citation.url, citation.snippet].compactMap { $0 }.joined(separator: " — ")
                append(result, line + "\n", font: NSFont.systemFont(ofSize: 12), color: ink)
            }
        }
        if !message.toolResults.isEmpty || !message.toolCalls.isEmpty {
            append(result, "\nTools\n", font: NSFont.systemFont(ofSize: 11, weight: .semibold), color: HearthTheme.accent)
            for call in message.toolCalls where message.toolResults.allSatisfy({ $0.id != call.id }) {
                append(result, "\(call.name) \(call.arguments)\n", font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), color: ink)
            }
            for tool in message.toolResults {
                append(result, "\(tool.name): \(tool.output)\n", font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), color: tool.isError ? .systemRed : ink)
            }
        }
        if let error = message.errorMessage, message.status != .complete {
            append(result, "\n\(error)", font: NSFont.systemFont(ofSize: 12), color: .systemRed)
        }
        _ = width
        return result
    }

    static func image(from source: String) -> NSImage? {
        if source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") {
            let encoded = String(source[source.index(after: comma)...])
            if let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
                return NSImage(data: data)
            }
        }
        if source.hasPrefix("file:") {
            return URL(string: source).flatMap { NSImage(contentsOf: $0) }
        }
        if source.hasPrefix("/") {
            return NSImage(contentsOfFile: source)
        }
        return nil
    }

    private static func append(
        _ result: NSMutableAttributedString,
        _ text: String,
        font: NSFont,
        color: NSColor,
        background: NSColor? = nil
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        if let background {
            attributes[.backgroundColor] = background
        }
        result.append(NSAttributedString(string: text, attributes: attributes))
    }
}

struct SidebarRepresentable: NSViewRepresentable, Equatable {
    @ObservedObject var model: WorkspaceModel

    static func == (lhs: SidebarRepresentable, rhs: SidebarRepresentable) -> Bool {
        lhs.model.sidebarRows == rhs.model.sidebarRows && lhs.model.selectedChatID == rhs.model.selectedChatID
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = HearthTheme.sidebar
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = HearthTheme.sidebar
        table.style = .sourceList
        table.rowHeight = 36
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.rows = model.sidebarRows
        context.coordinator.suppressSelection = true
        context.coordinator.table?.reloadData()
        if let index = model.sidebarRows.firstIndex(where: { entry in
            if case .chat(let id) = entry.kind { return id == model.selectedChatID }
            return false
        }) {
            context.coordinator.table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        context.coordinator.suppressSelection = false
    }
}

extension SidebarRepresentable {
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        nonisolated(unsafe) var rows: [SidebarEntry] = []
        nonisolated(unsafe) weak var table: NSTableView?
        nonisolated(unsafe) var suppressSelection = false
        nonisolated(unsafe) let model: WorkspaceModel

        init(model: WorkspaceModel) { self.model = model }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let entry = rows[row]
            let field = NSTextField(labelWithString: entry.subtitle.isEmpty ? entry.title : "\(entry.title)\n\(entry.subtitle)")
            field.maximumNumberOfLines = 2
            field.textColor = HearthTheme.ink
            field.font = entry.depth == 0
                ? NSFont.systemFont(ofSize: 13, weight: .semibold)
                : NSFont.systemFont(ofSize: 13)
            let cell = NSTableCellView()
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: CGFloat(12 + entry.depth * 14)),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !suppressSelection, let table, table.selectedRow >= 0, table.selectedRow < rows.count else { return }
            let entry = rows[table.selectedRow]
            MainActor.assumeIsolated {
                model.selectSidebar(entry)
            }
        }
    }
}

struct ConversationRepresentable: NSViewRepresentable, Equatable {
    @ObservedObject var model: WorkspaceModel

    static func == (lhs: ConversationRepresentable, rhs: ConversationRepresentable) -> Bool {
        lhs.model.transcriptGeneration == rhs.model.transcriptGeneration && lhs.model.scrollTarget == rhs.model.scrollTarget
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ConversationScrollView()
        scroll.probe = model.probe
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = HearthTheme.paper
        let table = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = HearthTheme.paper
        table.rowHeight = 72
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(model.messages, generation: model.transcriptGeneration, scrollTarget: model.scrollTarget)
    }
}

final class ConversationScrollView: NSScrollView {
    nonisolated(unsafe) var probe: PerformanceProbe?

    override func scrollWheel(with event: NSEvent) {
        let started = ContinuousClock.now
        super.scrollWheel(with: event)
        let elapsed = started.duration(to: ContinuousClock.now)
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        probe?.record(.scrolling, milliseconds: milliseconds)
    }
}

extension ConversationRepresentable {
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        nonisolated(unsafe) var messages: [Message] = []
        nonisolated(unsafe) var generation = 0
        nonisolated(unsafe) weak var table: NSTableView?
        nonisolated(unsafe) let model: WorkspaceModel
        nonisolated(unsafe) var heights: [UUID: CGFloat] = [:]

        init(model: WorkspaceModel) { self.model = model }

        func apply(_ messages: [Message], generation: Int, scrollTarget: UUID?) {
            let idsChanged = messages.map(\.id) != self.messages.map(\.id)
            self.messages = messages
            guard let table else { return }
            if idsChanged {
                heights.removeAll()
                table.reloadData()
                if let scrollTarget, let row = messages.firstIndex(where: { $0.id == scrollTarget }) {
                    table.scrollRowToVisible(row)
                } else if !messages.isEmpty {
                    table.scrollRowToVisible(messages.count - 1)
                }
            } else if generation != self.generation, let last = messages.indices.last {
                heights[messages[last].id] = nil
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: last))
                table.reloadData(forRowIndexes: IndexSet(integer: last), columnIndexes: IndexSet(integer: 0))
            }
            self.generation = generation
        }

        func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let message = messages[row]
            if let cached = heights[message.id] { return cached }
            let width = max(240, tableView.bounds.width - 32)
            let charactersPerLine = max(20, width / 7)
            let lines = ceil(Double(message.text.count + message.reasoning.count) / Double(charactersPerLine))
            let images = MainActor.assumeIsolated { model.renderedImageCount(for: message) }
            let height = min(1400, max(72, 36 + CGFloat(lines) * 18 + CGFloat(images) * 168))
            heights[message.id] = height
            return height
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let message = messages[row]
            let field = NSTextField(wrappingLabelWithString: "")
            field.attributedStringValue = MarkdownDrawing.attributed(message, width: tableView.bounds.width)
            field.isEditable = false
            field.isSelectable = true
            field.drawsBackground = false
            field.translatesAutoresizingMaskIntoConstraints = false
            let role = NSTextField(labelWithString: message.role.rawValue.capitalized)
            role.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            role.textColor = HearthTheme.accent
            role.translatesAutoresizingMaskIntoConstraints = false
            let cell = NSTableCellView()
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(role)
            cell.addSubview(stack)
            stack.addArrangedSubview(field)
            for block in MarkdownParser.parse(message.text) {
                if case .image(_, let source) = block, let image = MarkdownDrawing.image(from: source) {
                    stack.addArrangedSubview(Self.imageView(image))
                }
            }
            let attachmentImages = MainActor.assumeIsolated {
                message.attachmentIDs.compactMap { model.imageAttachmentData(id: $0) }
            }
            for data in attachmentImages {
                if let image = NSImage(data: data) {
                    stack.addArrangedSubview(Self.imageView(image))
                }
            }
            NSLayoutConstraint.activate([
                role.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                role.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: role.bottomAnchor, constant: 4),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -8),
                field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            ])
            return cell
        }

        private static func imageView(_ image: NSImage) -> NSImageView {
            let view = NSImageView()
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: 280).isActive = true
            view.heightAnchor.constraint(equalToConstant: 160).isActive = true
            return view
        }
    }
}

struct ComposerRepresentable: NSViewRepresentable, Equatable {
    @ObservedObject var model: WorkspaceModel

    static func == (lhs: ComposerRepresentable, rhs: ComposerRepresentable) -> Bool {
        lhs.model.phase == rhs.model.phase
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let textView = ComposerTextView()
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = HearthTheme.ink
        textView.backgroundColor = HearthTheme.paper
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.onSubmit = { context.coordinator.submit() }
        textView.minSize = NSSize(width: 0, height: 80)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if model.phase == .streaming, context.coordinator.didSend {
            context.coordinator.textView?.string = ""
            context.coordinator.didSend = false
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}

extension ComposerRepresentable {
    final class Coordinator: NSObject, NSTextViewDelegate {
        nonisolated(unsafe) let model: WorkspaceModel
        nonisolated(unsafe) weak var textView: ComposerTextView?
        nonisolated(unsafe) var didSend = false
        private var submitObserver: NSObjectProtocol?

        init(model: WorkspaceModel) {
            self.model = model
            super.init()
            submitObserver = NotificationCenter.default.addObserver(
                forName: .hearthSubmitComposer,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.submit()
                }
            }
        }

        deinit {
            if let submitObserver {
                NotificationCenter.default.removeObserver(submitObserver)
            }
        }

        func textDidChange(_ notification: Notification) {
            let started = ContinuousClock.now
            guard let textView else { return }
            let selected: String? = textView.selectedRange().length > 0
                ? (textView.string as NSString).substring(with: textView.selectedRange())
                : nil
            let elapsed = started.duration(to: ContinuousClock.now)
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            MainActor.assumeIsolated {
                if let selected {
                    model.currentSelection = selected
                }
                model.probe.record(.typing, milliseconds: milliseconds)
            }
        }

        func submit() {
            didSend = true
            let text = textView?.string ?? ""
            MainActor.assumeIsolated {
                model.send(draft: text, fileURLs: [])
            }
        }
    }
}
#endif
