# Hearth

Hearth is a native macOS workspace for local chats, projects, agents, prompts, workflows, and MCP tools. Chats and attachments stay on this Mac. API keys stay in the Keychain. There is no account, telemetry, or hosted chat service.

The interface is SwiftUI for the window shell and AppKit for the sidebar, transcript, composer, and Instant Chat panel. Core Data is the on-disk record. The tested snapshot format is the backup and export codec used by that store.

## First run

On macOS 14 or later, with Swift 6 installed:

```bash
./Hearth/Scripts/run.sh
```

That command builds the `Hearth` executable, wraps it in an unsigned app bundle so microphone and speech prompts have a stable bundle id (`com.hearth.local`), ad-hoc signs it, and opens it. The first launch creates an Inbox project, a General agent, and a Welcome chat under `~/Library/Application Support/Hearth`.

Ollama can be used with no API key. The default base URL is `http://127.0.0.1:11434`. Change it in Settings. Other providers need a key you paste into Settings; Hearth writes it to the login Keychain and clears the field.

## Setup

| Requirement | Notes |
| --- | --- |
| macOS 14 | SwiftUI app lifecycle, AppKit panels, and `NSRunningApplication.activate()` |
| Swift 6 | `swift build` / `swift test`. [swift.org/install](https://www.swift.org/install/) |
| Ollama (optional) | Local models through its HTTP API |
| OpenAI, Anthropic, or Gemini key (optional) | Stored in Keychain, not in chats or backups |

Provider calls use the documented HTTP APIs:

| Provider | Request |
| --- | --- |
| OpenAI | `POST https://api.openai.com/v1/chat/completions` with `Authorization: Bearer` |
| Anthropic | `POST https://api.anthropic.com/v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01` |
| Gemini | `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse&key=` |
| Ollama | `POST {base}/api/chat` |

Presets are `gpt-4o`, `gpt-4o-mini`, `claude-sonnet-4-5`, `claude-haiku-4-5`, `gemini-2.5-flash`, `gemini-2.5-pro`, and `llama3.2`. Pick a model on the chat's agent, or in Instant Chat.

## Permissions

The app is not sandboxed, so local MCP stdio processes and dictation paste-back can run.

| Permission | Why |
| --- | --- |
| Microphone | Instant Dictation capture |
| Speech Recognition | On-device transcription through `SFSpeechRecognizer` |
| Accessibility | Global hotkeys while another app is focused, and Command-V paste-back of a dictation |

Grant microphone and speech when macOS asks. Enable Accessibility in System Settings for Hearth if Control-Option shortcuts or paste-back do nothing while another app is in front.

| Shortcut | Action |
| --- | --- |
| Command-N | New chat |
| Command-Return | Send the composer draft |
| Control-Option-Space | Instant Chat panel (files, model, agent, tool names) |
| Control-Option-D | Start or finish Instant Dictation |
| Command-Comma | Settings |

Instant Dictation remembers the frontmost app, transcribes, then pastes the text there and restores the previous clipboard. If that app is Hearth, the text is inserted into the open chat instead.

## Using the workspace

The sidebar is an `NSTableView`. Chats live under projects. Search matches message text and shows hits in the sidebar. The transcript is an `NSTableView` that reloads the last row while a response streams, and the composer is an `NSTextView`. Draft text stays in that text view so keystrokes do not republish the transcript.

A turn can stream, be cancelled, retried, or regenerated. Cancelled and failed turns keep any text already received and stay retryable when the failure is a rate limit or a dropped connection. A relaunch marks leftover `streaming` rows as `interrupted` and keeps their text. The same recovery does not run twice.

Markdown in a reply is drawn as headings, paragraphs, code, lists, quotes, reasoning, citations, and tool results. Image markdown that uses a `data:` URL or a local file path, and image attachments, are drawn with `NSImageView`.

Agents, saved prompts, and workflows are in the Workspace menu. Workflow templates accept `{{selection}}`, `{{clipboard}}`, `{{files}}`, `{{input}}`, and `{{filename}}`. Required sources that the template never mentions are appended. Selection comes from the composer. Clipboard and files are read when you run the workflow.

MCP servers are either stdio (`command` plus arguments) or HTTP. Hearth speaks the `2024-11-05` protocol: initialize, `notifications/initialized`, `tools/list`, and `tools/call`, with Content-Length framing for stdio. An agent's tool list chooses which tools are offered. An empty list offers none. Tool rounds stop after four.

## Performance testing

Navigation, typing, scroll-wheel events, and completed streams record millisecond samples in process. Open Settings to read the averages.

To exercise a large transcript:

1. Choose Workspace → Seed Large History. Hearth writes 5,000 messages into a Performance project.
2. Select that chat, scroll the transcript, and type in the composer.
3. Open Settings and read the navigation, typing, scrolling, and streaming averages.

For a system trace on macOS, launch the app and use Instruments (Time Profiler and SwiftUI). The sidebar and transcript skip SwiftUI updates when their rows have not changed, and streaming refreshes only the last transcript row.

The focused persistence tests also build a large snapshot history and assert navigation, typing, scrolling, and windowing stay within fixed bounds. Run those with the command below.

## Data

| Item | Location |
| --- | --- |
| Core Data store | `~/Library/Application Support/Hearth/hearth.sqlite` |
| Attachment files | `~/Library/Application Support/Hearth/attachments/` |
| Keychain service | `com.hearth.local.credentials` (accounts `openai`, `anthropic`, `gemini`, `ollama`) |
| Ollama base URL | UserDefaults key `hearth.ollamaBaseURL` |

Workspace → Export Chat writes one chat as `hearth.chat.v1` JSON, including attachment bytes and omitting Keychain secrets. Workspace → Backup writes a folder named `Hearth Backup <timestamp>` with `manifest.json` (`hearth.backup.v1`), `store.json`, and `attachments/`. Restore replaces the local library with that folder. Quit Hearth before copying the Application Support directory by hand.

## Tests

From the `Hearth` directory, with Swift 6 on `PATH`:

```bash
swift test
```

`HearthCoreTests` covers snapshot persistence and relaunch, forked chats, full-text search, export and backup, interrupted streams, streaming cancellation and retry, workflow inputs, and provider request and stream translation, including a local stdio MCP process. On macOS the same command also runs `HearthMacTests`, which reopens a Core Data store and checks that a partial streaming row survives relaunch.

These tests do not call OpenAI, Anthropic, or Gemini.

## Limitations

Hearth deliberately does not include cloud sync, mobile apps, teams, a hosted model service, billing, licensing, telemetry, or analytics. It does not import other apps' chat archives with full fidelity, execute model-authored code, or add providers beyond OpenAI, Anthropic, Gemini, and Ollama.

MCP support is the basic list and call flow for one local stdio server or one remote HTTP endpoint per configured server, with per-agent tool names. It is not a full client for every server feature. Dictation uses the system speech recognizer and pastes text; it does not edit the target app through a private accessibility tree. Image rendering covers data URLs, local file paths, and saved image attachments, not remote image fetches during layout.
