#if os(macOS)
import AppKit
import AVFoundation
import Foundation
import Speech
import HearthCore

@MainActor
public final class DictationController: NSObject, SFSpeechRecognizerDelegate {
    public var onDeliver: @MainActor (String) -> Void = { _ in }
    public var onStatus: @MainActor (String) -> Void = { _ in }
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var state = DictationState()

    public func toggle() {
        if state.phase == .listening {
            finish()
        } else {
            start()
        }
    }

    public func start() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "com.hearth.local"
        state = DictationReducer.reduce(DictationState(), .start(targetBundleID: bundleID))
        onStatus("Listening")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.fail("Speech recognition permission is not granted.")
                    return
                }
                self.beginCapture()
            }
        }
    }

    public func finish() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.cancel()
        state = DictationReducer.reduce(state, .finish)
        state = DictationReducer.reduce(state, .deliver)
        guard let plan = DictationPlanner.plan(state: state) else {
            onStatus(state.error ?? "Dictation did not produce text.")
            state = DictationReducer.reduce(state, .reset)
            return
        }
        if plan.targetBundleID == Bundle.main.bundleIdentifier {
            onDeliver(plan.text)
        } else {
            paste(plan)
        }
        onStatus("Returned dictation to \(plan.targetBundleID).")
        state = DictationReducer.reduce(state, .reset)
    }

    private func beginCapture() {
        guard let recognizer, recognizer.isAvailable else {
            fail("Speech recognition is unavailable.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            fail("The microphone could not start.")
            return
        }
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let text = result?.bestTranscription.formattedString {
                    self.state = DictationReducer.reduce(self.state, .partial(text))
                    self.onStatus(text)
                }
                if error != nil && self.state.phase == .listening {
                    self.fail("Speech recognition stopped.")
                }
            }
        }
    }

    private func paste(_ plan: DictationDeliveryPlan) {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(plan.text, forType: .string)
        NSRunningApplication.runningApplications(withBundleIdentifier: plan.targetBundleID).first?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Self.postCommandV()
            guard plan.restoresPreviousClipboard else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pasteboard.clearContents()
                if let previous {
                    pasteboard.setString(previous, forType: .string)
                }
            }
        }
    }

    private func fail(_ message: String) {
        state = DictationReducer.reduce(state, .fail(message))
        onStatus(message)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
#endif
