import XCTest
@testable import HearthCore

final class WorkflowTests: XCTestCase {
    func testSelectionClipboardAndFilesResolveIntoPrompt() throws {
        let workflow = Workflow(
            id: UUID(),
            name: "Rewrite",
            template: "Selection:\n{{selection}}\n\nClipboard:\n{{clipboard}}\n\nFiles:\n{{files}}\n\nName: {{filename}}",
            sources: [.selection, .clipboard, .files]
        )
        let resolved = try WorkflowEngine.resolve(
            workflow: workflow,
            prompt: nil,
            agent: nil,
            inputs: WorkflowInputs(
                selection: "selected line",
                clipboard: "copied line",
                files: [WorkflowFile(name: "notes.txt", text: "file body")]
            ),
            fallbackModel: .defaultModel
        )
        XCTAssertTrue(resolved.prompt.contains("selected line"))
        XCTAssertTrue(resolved.prompt.contains("copied line"))
        XCTAssertTrue(resolved.prompt.contains("file body"))
        XCTAssertTrue(resolved.prompt.contains("notes.txt"))
        XCTAssertEqual(resolved.model, .defaultModel)
    }

    func testMissingSourcesFailAndSavedPromptIsReused() throws {
        let workflow = Workflow(
            id: UUID(),
            name: "Explain",
            template: "",
            sources: [.selection, .clipboard],
            agentID: nil
        )
        XCTAssertThrowsError(try WorkflowEngine.resolve(
            workflow: workflow,
            prompt: SavedPrompt(id: UUID(), title: "Explain", body: "Explain {{selection}}", createdAt: Date()),
            agent: nil,
            inputs: WorkflowInputs(selection: "", clipboard: "clip"),
            fallbackModel: .defaultModel
        )) { error in
            XCTAssertEqual(error as? WorkflowError, .missingSelection)
        }

        let prompt = SavedPrompt(id: UUID(), title: "Explain", body: "Explain {{selection}}", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let resolved = try WorkflowEngine.resolve(
            workflow: workflow,
            prompt: prompt,
            agent: nil,
            inputs: WorkflowInputs(selection: "this paragraph", clipboard: "unused but present"),
            fallbackModel: .defaultModel
        )
        XCTAssertTrue(resolved.prompt.contains("Explain this paragraph"))
        XCTAssertTrue(resolved.prompt.contains("unused but present"))
    }

    func testFilesAppendWhenTemplateOmitsPlaceholderAndBinaryIsMarked() throws {
        let workflow = Workflow(id: UUID(), name: "Files", template: "Summarize the files.", sources: [.files])
        let resolved = try WorkflowEngine.resolve(
            workflow: workflow,
            prompt: nil,
            agent: nil,
            inputs: WorkflowInputs(files: [
                FileTextLoader.load(name: "note.txt", data: Data("alpha".utf8)),
                FileTextLoader.load(name: "blob.bin", data: Data([0, 1, 2, 255])),
            ]),
            fallbackModel: ModelRef(provider: .openAI, name: "gpt-4o")
        )
        XCTAssertTrue(resolved.prompt.contains("alpha"))
        XCTAssertTrue(resolved.prompt.contains("blob.bin"))
        XCTAssertTrue(resolved.prompt.contains("Binary"))
        XCTAssertEqual(resolved.model.name, "gpt-4o")
    }

    func testAgentBindingSuppliesSystemPromptAndModel() throws {
        let agent = Agent(
            id: UUID(),
            name: "Editor",
            systemPrompt: "Edit tightly.",
            model: ModelRef(provider: .anthropic, name: "claude-sonnet-4-5"),
            temperature: 0.2
        )
        let workflow = Workflow(id: UUID(), name: "Edit", template: "Edit {{clipboard}}", sources: [.clipboard], agentID: agent.id)
        let resolved = try WorkflowEngine.resolve(
            workflow: workflow,
            prompt: nil,
            agent: agent,
            inputs: WorkflowInputs(clipboard: "draft"),
            fallbackModel: .defaultModel
        )
        XCTAssertEqual(resolved.systemPrompt, "Edit tightly.")
        XCTAssertEqual(resolved.model, agent.model)
        XCTAssertEqual(resolved.agentID, agent.id)
        XCTAssertEqual(resolved.prompt, "Edit draft")
    }

    func testInstantChatIncludesFilesAgentAndSelectedTools() {
        let agent = Agent(
            id: UUID(),
            name: "General",
            systemPrompt: "Stay local.",
            model: .defaultModel,
            temperature: 0.4,
            enabledToolNames: ["echo"]
        )
        let echo = ToolDefinition(name: "echo", description: "Echo", jsonSchema: "{\"type\":\"object\"}")
        let write = ToolDefinition(name: "write", description: "Write", jsonSchema: "{\"type\":\"object\"}")
        let draft = InstantChatDraft(
            text: "Summarize",
            files: [WorkflowFile(name: "a.txt", text: "alpha")],
            agent: agent,
            model: agent.model,
            enabledToolNames: agent.enabledToolNames,
            allowedTools: [echo, write]
        )
        let request = draft.makeRequest()
        XCTAssertEqual(request.messages.first?.role, .system)
        XCTAssertEqual(request.messages.first?.text, "Stay local.")
        XCTAssertTrue(request.messages.contains { $0.role == .user && $0.text.contains("alpha") && $0.text.contains("Summarize") })
        XCTAssertEqual(request.tools.map(\.name), ["echo"])
        XCTAssertEqual(request.temperature, 0.4)
        XCTAssertTrue(request.stream)
    }

    func testDictationReturnsTextToTheOriginalApplication() {
        var state = DictationState()
        state = DictationReducer.reduce(state, .start(targetBundleID: "com.example.editor"))
        state = DictationReducer.reduce(state, .partial("hello"))
        state = DictationReducer.reduce(state, .partial("hello world"))
        state = DictationReducer.reduce(state, .finish)
        state = DictationReducer.reduce(state, .deliver)
        let plan = DictationPlanner.plan(state: state)
        XCTAssertEqual(plan, DictationDeliveryPlan(targetBundleID: "com.example.editor", text: "hello world", restoresPreviousClipboard: true))

        var empty = DictationReducer.reduce(DictationState(), .start(targetBundleID: "com.example.editor"))
        empty = DictationReducer.reduce(empty, .finish)
        empty = DictationReducer.reduce(empty, .deliver)
        XCTAssertEqual(empty.phase, .failed)
        XCTAssertNil(DictationPlanner.plan(state: empty))
    }
}
