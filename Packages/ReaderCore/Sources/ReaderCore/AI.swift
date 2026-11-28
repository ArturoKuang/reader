import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum AIError: Error, Equatable, Sendable {
    case missingKey(provider: String)
    case missingCLI(name: String)
    case failed(provider: String, detail: String)

    public var userMessage: String {
        switch self {
        case .missingKey(let provider):
            return "Add a \(provider) API key in Settings."
        case .missingCLI(let name):
            return "\(name) was not found. Set its path in Settings."
        case .failed(let provider, let detail):
            return detail.isEmpty ? "\(provider) didn't answer." : "\(provider): \(detail)"
        }
    }
}

public struct HTTPRequest: Equatable, Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: Data

    public init(url: String, method: String, headers: [String: String], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public var text: String { String(data: body, encoding: .utf8) ?? "" }
}

public protocol HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url) else { throw ReaderFailure("Bad URL \(request.url)") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(status: status, body: data)
    }
}

public struct CLIInvocation: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?

    public init(executable: String, arguments: [String], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var cancelled: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool, cancelled: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
    }
}

public protocol CommandRunning: AnyObject {
    func run(_ invocation: CLIInvocation, timeout: TimeInterval, onStdout: @escaping (String) -> Void) throws -> CommandResult
    func cancel()
}

public enum ClaudeCommand {
    /// Flags checked against the Claude Code CLI, not the design draft's guess.
    /// `--print` is the non-interactive mode (`-p` is the same flag).
    /// `--tools` restricts the built-in set; `--allowedTools` only auto-approves and does not restrict.
    /// `stream-json` requires `--verbose`. `--permission-mode dontAsk` denies anything
    /// that would otherwise block on a dialog. `--` ends the variadic tool list so the prompt is not swallowed.
    public static let readOnlyTools = "Read,Grep,Glob"

    public static func invocation(executable: String, prompt: String, workingDirectory: String) -> CLIInvocation {
        CLIInvocation(
            executable: executable,
            arguments: [
                "--print",
                "--verbose",
                "--output-format", "stream-json",
                "--permission-mode", "dontAsk",
                "--tools", readOnlyTools,
                "--allowedTools", readOnlyTools,
                "--",
                prompt,
            ],
            workingDirectory: workingDirectory
        )
    }

    /// Lightweight, low-latency invocation for word definitions: skips MCP/slash plugins and
    /// uses Sonnet at low effort with no tools or session persistence.
    public static func fastLookupInvocation(
        executable: String,
        prompt: String,
        workingDirectory: String,
        model: String = "sonnet",
        effort: String = "low"
    ) -> CLIInvocation {
        CLIInvocation(
            executable: executable,
            arguments: [
                "--print",
                "--verbose",
                "--output-format", "stream-json",
                "--no-session-persistence",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--model", model,
                "--effort", effort,
                "--tools", "",
                "--",
                prompt,
            ],
            workingDirectory: workingDirectory
        )
    }
}

public enum CodexCommand {
    /// `codex exec` is the non-interactive command. `--sandbox read-only` keeps it read-only.
    /// `-c approval_policy="never"` prevents blocking prompts (modern `codex exec` rejects `--ask-for-approval`).
    /// `--skip-git-repo-check` allows running in temp workspaces; `--ephemeral` skips session rollout files.
    public static func invocation(executable: String, prompt: String, workingDirectory: String, model: String? = nil, effort: String? = nil) -> CLIInvocation {
        var args = [
            "exec",
            "--sandbox", "read-only",
            "-c", "approval_policy=\"never\"",
            "--skip-git-repo-check",
            "--ephemeral",
            "--json",
        ]
        if let model, !model.isEmpty {
            args.append(contentsOf: ["--ignore-user-config", "-m", model])
        }
        if let effort, !effort.isEmpty {
            args.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""])
        }
        args.append(contentsOf: ["-C", workingDirectory, prompt])
        return CLIInvocation(executable: executable, arguments: args, workingDirectory: workingDirectory)
    }

    public static func fastLookupInvocation(
        executable: String,
        prompt: String,
        workingDirectory: String,
        model: String? = nil,
        effort: String = "low"
    ) -> CLIInvocation {
        let resolvedModel = model ?? resolveSolModel(home: NSHomeDirectory())
        return invocation(executable: executable, prompt: prompt, workingDirectory: workingDirectory, model: resolvedModel, effort: effort)
    }

    /// Resolves the best available Sol model from `~/.codex/models_cache.json`, preferring `gpt-6.2-sol`
    /// and falling back to the highest available `*-sol` slug (e.g. `gpt-6.1-sol`).
    public static func resolveSolModel(home: String, fs: FileSystem = LocalFileSystem()) -> String {
        let cachePath = Paths.join(home, ".codex/models_cache.json")
        guard let data = try? fs.read(cachePath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            return "gpt-6.2-sol"
        }
        let visibleModels = models.filter { ($0["visibility"] as? String) != "hide" }
        let slugs = (visibleModels.isEmpty ? models : visibleModels).compactMap { $0["slug"] as? String }
        if slugs.contains("gpt-6.2-sol") { return "gpt-6.2-sol" }
        let sols = slugs.filter { $0.lowercased().contains("sol") }
        if let best = sols.sorted(by: { lhs, rhs in lhs.localizedStandardCompare(rhs) == .orderedDescending }).first {
            return best
        }
        return slugs.first ?? "gpt-6.2-sol"
    }
}

public enum GeminiCommand {
    /// Non-interactive headless Gemini CLI invocation. Uses `--skip-trust` so temporary directories
    /// do not block on workspace trust prompts.
    public static func invocation(
        executable: String,
        prompt: String,
        workingDirectory: String,
        model: String = "gemini-4-neon"
    ) -> CLIInvocation {
        var args = ["--skip-trust", "-o", "json"]
        if !model.isEmpty {
            args.append(contentsOf: ["-m", model])
        }
        args.append(contentsOf: ["-p", prompt])
        return CLIInvocation(executable: executable, arguments: args, workingDirectory: workingDirectory)
    }
}

public enum CLIOutput {
    /// Claude's stream-json events carry `session_id`. Reader stores it so the next tutor turn can `--resume`.
    public static func claudeSessionID(_ stdout: String) -> String? {
        var found: String?
        for line in stdout.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let json = JSONValue.parse(text)?.object else { continue }
            if let id = json["session_id"]?.string, !id.isEmpty { found = id }
        }
        return found
    }

    public static func parseClaude(_ stdout: String) throws -> String {
        var assistant = ""
        var result: String?
        var errorMessage: String?
        for line in stdout.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let json = JSONValue.parse(text)?.object else { continue }
            let type = json["type"]?.string
            if type == "result" {
                if json["is_error"]?.bool == true {
                    errorMessage = json["result"]?.string ?? "Claude Code returned an error."
                } else if let value = json["result"]?.string {
                    result = value
                }
            } else if type == "assistant" {
                assistant += assistantText(json["message"])
            }
        }
        if let errorMessage { throw ReaderFailure(errorMessage) }
        if let result, !result.isEmpty { return result }
        if !assistant.isEmpty { return assistant }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ReaderFailure("Claude Code returned no text.") }
        return trimmed
    }

    public static func parseCodex(_ stdout: String) throws -> String {
        var latest = ""
        var failed: String?
        for line in stdout.split(separator: "\n") {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard let json = JSONValue.parse(text)?.object else { continue }
            let type = json["type"]?.string ?? ""
            if type == "turn.failed" || type == "error" {
                failed = json["message"]?.string ?? json["error"]?.string ?? "Codex failed."
            }
            if let item = json["item"]?.object, item["type"]?.string == "agent_message", let message = item["text"]?.string, !message.isEmpty {
                latest = message
            }
            if type == "agent_message", let message = json["text"]?.string, !message.isEmpty {
                latest = message
            }
        }
        if !latest.isEmpty { return latest }
        if let failed { throw ReaderFailure(failed) }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ReaderFailure("Codex returned no text.") }
        return trimmed
    }

    public static func parseGemini(_ stdout: String) throws -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ReaderFailure("Gemini returned no text.") }
        if let json = JSONValue.parse(trimmed)?.object {
            if let error = json["error"]?["message"]?.string, !error.isEmpty {
                throw ReaderFailure(error)
            }
            if let response = json["response"]?.string, !response.isEmpty { return response }
            if let text = json["text"]?.string, !text.isEmpty { return text }
        }
        for line in trimmed.split(separator: "\n").reversed() {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard let json = JSONValue.parse(s)?.object else { continue }
            if let response = json["response"]?.string, !response.isEmpty { return response }
            if let text = json["text"]?.string, !text.isEmpty { return text }
        }
        return trimmed
    }

    private static func assistantText(_ message: JSONValue?) -> String {
        guard let content = message?["content"]?.array else { return "" }
        return content.compactMap { block -> String? in
            guard block["type"]?.string == "text" else { return nil }
            return block["text"]?.string
        }.joined()
    }
}

public enum CLIWorkspace {
    public static let prompt = "Answer the question in focus.md. Use book.txt for context and cite pages. Do not modify any files."

    public static func write(
        directory: String,
        book: BookText,
        focus: Focus?,
        question: String,
        originalBookPath: String?,
        fs: FileSystem
    ) throws {
        try fs.createDirectory(directory)
        try fs.writeString(Paths.join(directory, "book.txt"), PromptAssembly.bookFile(book))
        try fs.writeString(Paths.join(directory, "focus.md"), PromptAssembly.focusFile(book: book, focus: focus, question: question))
        if let originalBookPath {
            let linkName = Paths.name(originalBookPath)
            if !linkName.isEmpty {
                try? fs.symlink(target: originalBookPath, linkAt: Paths.join(directory, linkName))
            }
        }
    }
}

public enum OpenAIProvider {
    public static func request(apiKey: String, model: String, system: String, user: String, stream: Bool) -> HTTPRequest {
        let payload: [String: Any] = [
            "model": model,
            "stream": stream,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return HTTPRequest(
            url: "https://api.openai.com/v1/chat/completions",
            method: "POST",
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
            ],
            body: body
        )
    }

    public static func parse(_ body: String) throws -> String {
        if body.contains("data:") {
            var text = ""
            for line in body.split(separator: "\n") {
                let raw = String(line).trimmingCharacters(in: .whitespaces)
                guard raw.hasPrefix("data:") else { continue }
                let payload = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { continue }
                guard let json = JSONValue.parse(String(payload)) else { continue }
                if let delta = json["choices"]?.array?.first?["delta"]?["content"]?.string {
                    text += delta
                }
            }
            if !text.isEmpty { return text }
        }
        if let json = JSONValue.parse(body), let content = json["choices"]?.array?.first?["message"]?["content"]?.string {
            return content
        }
        throw ReaderFailure("OpenAI returned no text.")
    }
}

public enum AnthropicProvider {
    public static func request(apiKey: String, model: String, system: String, user: String, stream: Bool) -> HTTPRequest {
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": stream,
            "system": system,
            "messages": [
                ["role": "user", "content": user],
            ],
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return HTTPRequest(
            url: "https://api.anthropic.com/v1/messages",
            method: "POST",
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
            ],
            body: body
        )
    }

    public static func parse(_ body: String) throws -> String {
        if body.contains("content_block_delta") || body.contains("data:") {
            var text = ""
            for line in body.split(separator: "\n") {
                let raw = String(line).trimmingCharacters(in: .whitespaces)
                guard raw.hasPrefix("data:") else { continue }
                let payload = raw.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let json = JSONValue.parse(String(payload)) else { continue }
                if json["type"]?.string == "content_block_delta", let delta = json["delta"]?["text"]?.string {
                    text += delta
                }
            }
            if !text.isEmpty { return text }
        }
        if let json = JSONValue.parse(body) {
            if let text = json["content"]?.array?.first?["text"]?.string { return text }
            if let message = json["error"]?["message"]?.string { throw ReaderFailure(message) }
        }
        throw ReaderFailure("Anthropic returned no text.")
    }
}

public struct AIResult: Equatable, Sendable {
    public var text: String
    public var provider: ProviderID
    public var providerLabel: String
    public var contextMode: ContextMode

    public init(text: String, provider: ProviderID, providerLabel: String, contextMode: ContextMode) {
        self.text = text
        self.provider = provider
        self.providerLabel = providerLabel
        self.contextMode = contextMode
    }
}

public enum ProviderLabels {
    public static func describe(_ provider: ProviderID, contextMode: ContextMode) -> String {
        let scope: String
        switch (provider, contextMode) {
        case (_, .wholeBook) where provider == .openai:
            scope = "whole book sent, your selection as focus"
        case (_, .chapterPlusPassages) where provider == .openai:
            scope = "current chapter plus related passages (the book is longer than the context window)"
        case (_, .wholeBook) where provider == .anthropic:
            scope = "whole book sent, your selection as focus"
        case (_, .chapterPlusPassages):
            scope = "current chapter plus related passages (the book is longer than the context window)"
        default:
            scope = "whole book sent, your selection as focus"
        }
        switch provider {
        case .openai:
            return "Answered by ChatGPT via the OpenAI API · \(scope)"
        case .anthropic:
            return "Answered by Claude via the Anthropic API · \(scope)"
        case .claudeCLI:
            return "Answered by Claude Code (`claude --print`) · read the whole book, focused on your selection"
        case .codexCLI:
            return "Answered by Codex (`codex exec`) · read the whole book, focused on your selection"
        case .geminiCLI:
            return "Answered by Gemini CLI (`gemini -p`) · focused on your selection"
        }
    }
}

/// Structured word lookup response for the Preview-like definition bubble and Words sidebar.
public struct WordDefinitionResult: Equatable, Sendable {
    public var partOfSpeech: String
    public var definition: String
    public var inContext: String

    public init(partOfSpeech: String = "", definition: String, inContext: String = "") {
        self.partOfSpeech = partOfSpeech
        self.definition = definition
        self.inContext = inContext
    }
}

public enum WordLookupParser {
    public static func prompt(word: String, sentence: String, bookTitle: String?, section: String?) -> String {
        var lines = [
            "Define the word \"\(word)\" concisely like the macOS Preview dictionary popup.",
            "Return ONLY a JSON object with keys: \"partOfSpeech\" (e.g. noun, verb, adjective), \"definition\" (1 clear, concise sentence), and \"inContext\" (1 short plain-language sentence explaining what it means in the passage below).",
        ]
        if let bookTitle, !bookTitle.isEmpty {
            lines.append("Book: \(bookTitle)")
        }
        if let section, !section.isEmpty {
            lines.append("Section: \(section)")
        }
        if !sentence.isEmpty {
            lines.append("Sentence: \"\(sentence)\"")
        }
        return lines.joined(separator: "\n")
    }

    public static func parse(_ raw: String) -> WordDefinitionResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jsonObj = extractJSON(trimmed) {
            let pos = (jsonObj["partOfSpeech"]?.string ?? jsonObj["part_of_speech"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let def = (jsonObj["definition"]?.string ?? jsonObj["meaning"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ctx = (jsonObj["inContext"]?.string ?? jsonObj["in_context"]?.string ?? jsonObj["explanation"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !def.isEmpty || !ctx.isEmpty {
                return WordDefinitionResult(partOfSpeech: pos, definition: def.isEmpty ? ctx : def, inContext: ctx)
            }
        }
        // Fallback: split first sentence as definition, remainder as context if multi-paragraph.
        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paragraphs.count >= 2 {
            return WordDefinitionResult(definition: paragraphs[0], inContext: paragraphs.dropFirst().joined(separator: " "))
        }
        return WordDefinitionResult(definition: trimmed, inContext: "")
    }

    private static func extractJSON(_ text: String) -> [String: JSONValue]? {
        if let parsed = JSONValue.parse(text)?.object { return parsed }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return JSONValue.parse(String(text[start...end]))?.object
    }
}

public struct FastLookupCandidate: Equatable, Sendable {
    public var provider: ProviderID
    public var executable: String
    public var model: String
    public var label: String

    public init(provider: ProviderID, executable: String, model: String, label: String) {
        self.provider = provider
        self.executable = executable
        self.model = model
        self.label = label
    }
}

/// Picks the fastest available low-effort lookup model among Sonnet, Sol 6.2 (or latest Sol),
/// and Gemini 4 Neon, caching observed latency and falling back automatically if a backend fails.
public final class FastLookupRouter: @unchecked Sendable {
    public static let shared = FastLookupRouter()
    private let lock = NSLock()
    private var latencySeconds: [ProviderID: TimeInterval] = [:]
    private var failedUntil: [ProviderID: Date] = [:]

    public init() {}

    public func candidates(
        claudePath: String?,
        codexPath: String?,
        geminiPath: String?,
        codexSolModel: String? = nil,
        now: Date = Date()
    ) -> [FastLookupCandidate] {
        var list: [FastLookupCandidate] = []
        if let claudePath, !claudePath.isEmpty {
            list.append(FastLookupCandidate(provider: .claudeCLI, executable: claudePath, model: "sonnet", label: "Sonnet · low effort"))
        }
        if let codexPath, !codexPath.isEmpty {
            let model = codexSolModel ?? CodexCommand.resolveSolModel(home: NSHomeDirectory())
            let display = model.replacingOccurrences(of: "gpt-", with: "").replacingOccurrences(of: "-sol", with: "")
            let label = display.isEmpty ? "Sol · low effort" : "Sol \(display) · low effort"
            list.append(FastLookupCandidate(provider: .codexCLI, executable: codexPath, model: model, label: label))
        }
        if let geminiPath, !geminiPath.isEmpty {
            list.append(FastLookupCandidate(provider: .geminiCLI, executable: geminiPath, model: "gemini-4-neon", label: "Gemini 4 Neon · low effort"))
        }

        lock.lock()
        let latencies = latencySeconds
        let cooldowns = failedUntil
        lock.unlock()

        // Default speed order before measurements: Sonnet (0) -> Sol (1) -> Gemini 4 Neon (2).
        // Healthy providers ordered by measured latency come before providers in failure cooldown.
        func defaultRank(_ provider: ProviderID) -> Double {
            switch provider {
            case .claudeCLI: return 100
            case .codexCLI: return 200
            case .geminiCLI: return 300
            default: return 400
            }
        }
        return list.sorted { lhs, rhs in
            let lhsCooling = (cooldowns[lhs.provider] ?? .distantPast) > now
            let rhsCooling = (cooldowns[rhs.provider] ?? .distantPast) > now
            if lhsCooling != rhsCooling { return !lhsCooling }
            let lScore = latencies[lhs.provider] ?? defaultRank(lhs.provider)
            let rScore = latencies[rhs.provider] ?? defaultRank(rhs.provider)
            return lScore < rScore
        }
    }

    public func recordSuccess(provider: ProviderID, elapsed: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if let prev = latencySeconds[provider] {
            latencySeconds[provider] = prev * 0.6 + elapsed * 0.4
        } else {
            latencySeconds[provider] = elapsed
        }
        failedUntil[provider] = nil
    }

    public func recordFailure(provider: ProviderID, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        failedUntil[provider] = now.addingTimeInterval(300)
    }

    public func lookup(
        word: String,
        sentence: String,
        bookTitle: String?,
        section: String?,
        candidates: [FastLookupCandidate],
        workingDirectory: String,
        runner: CommandRunning,
        timeout: TimeInterval = 45
    ) throws -> (result: WordDefinitionResult, providerLabel: String, provider: ProviderID) {
        guard !candidates.isEmpty else {
            throw AIError.missingCLI(name: "Claude Code, Codex, or Gemini CLI")
        }
        let prompt = WordLookupParser.prompt(word: word, sentence: sentence, bookTitle: bookTitle, section: section)
        var lastError: Error = ReaderFailure("No fast lookup model responded.")
        for candidate in candidates {
            let invocation: CLIInvocation
            switch candidate.provider {
            case .claudeCLI:
                invocation = ClaudeCommand.fastLookupInvocation(
                    executable: candidate.executable,
                    prompt: prompt,
                    workingDirectory: workingDirectory,
                    model: candidate.model,
                    effort: "low"
                )
            case .codexCLI:
                invocation = CodexCommand.fastLookupInvocation(
                    executable: candidate.executable,
                    prompt: prompt,
                    workingDirectory: workingDirectory,
                    model: candidate.model,
                    effort: "low"
                )
            case .geminiCLI:
                invocation = GeminiCommand.invocation(
                    executable: candidate.executable,
                    prompt: prompt,
                    workingDirectory: workingDirectory,
                    model: candidate.model
                )
            default:
                continue
            }
            let started = Date()
            do {
                let output = try runner.run(invocation, timeout: timeout) { _ in }
                if output.cancelled { throw ReaderFailure("Stopped.") }
                if output.timedOut {
                    recordFailure(provider: candidate.provider)
                    lastError = ReaderFailure("\(candidate.label) timed out.")
                    continue
                }
                let rawText: String
                switch candidate.provider {
                case .claudeCLI: rawText = try CLIOutput.parseClaude(output.stdout)
                case .codexCLI: rawText = try CLIOutput.parseCodex(output.stdout)
                case .geminiCLI:
                    if output.exitCode != 0 {
                        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw ReaderFailure(detail.isEmpty ? "Gemini exited with status \(output.exitCode)." : detail)
                    }
                    rawText = try CLIOutput.parseGemini(output.stdout)
                default: rawText = ""
                }
                if output.exitCode != 0 && rawText.isEmpty {
                    let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw ReaderFailure(detail.isEmpty ? "\(candidate.label) exited with status \(output.exitCode)." : detail)
                }
                let parsed = WordLookupParser.parse(rawText)
                recordSuccess(provider: candidate.provider, elapsed: Date().timeIntervalSince(started))
                return (parsed, candidate.label, candidate.provider)
            } catch {
                recordFailure(provider: candidate.provider)
                lastError = error
                continue
            }
        }
        throw lastError
    }
}

public final class AIRouter {
    public var settings: AISettings
    public var openAIKey: String?
    public var anthropicKey: String?
    public var transport: HTTPTransport
    public var runner: CommandRunning
    public var onDelta: (String) -> Void

    public init(settings: AISettings, openAIKey: String? = nil, anthropicKey: String? = nil, transport: HTTPTransport, runner: CommandRunning, onDelta: @escaping (String) -> Void = { _ in }) {
        self.settings = settings
        self.openAIKey = openAIKey
        self.anthropicKey = anthropicKey
        self.transport = transport
        self.runner = runner
        self.onDelta = onDelta
    }

    /// Sends immediately. Callers must not add a confirmation step.
    public func answer(
        book: BookText,
        focus: Focus?,
        purpose: AIPurpose,
        provider override: ProviderID? = nil,
        cliDirectory: String,
        originalBookPath: String? = nil,
        fs: FileSystem,
        timeout: TimeInterval = 180
    ) async throws -> AIResult {
        let provider = resolve(purpose, override: override)
        if provider.isCLI {
            return try runCLI(provider: provider, book: book, focus: focus, purpose: purpose, directory: cliDirectory, originalBookPath: originalBookPath, fs: fs, timeout: timeout)
        }
        let budget = max(256, settings.contextTokens(for: provider) - 4096)
        let prompt = PromptAssembly.assemble(book: book, focus: focus, purpose: purpose, tokenBudget: budget)
        let text: String
        switch provider {
        case .openai:
            guard let key = openAIKey, !key.isEmpty else { throw ReaderFailure("Add an OpenAI API key in Settings.") }
            let request = OpenAIProvider.request(apiKey: key, model: settings.openAIModel, system: prompt.system, user: prompt.user, stream: true)
            let response = try await transport.send(request)
            guard (200..<300).contains(response.status) else {
                throw ReaderFailure("OpenAI returned HTTP \(response.status). \(response.text.prefix(400))")
            }
            text = try OpenAIProvider.parse(response.text)
        case .anthropic:
            guard let key = anthropicKey, !key.isEmpty else { throw ReaderFailure("Add an Anthropic API key in Settings.") }
            let request = AnthropicProvider.request(apiKey: key, model: settings.anthropicModel, system: prompt.system, user: prompt.user, stream: true)
            let response = try await transport.send(request)
            guard (200..<300).contains(response.status) else {
                throw ReaderFailure("Anthropic returned HTTP \(response.status). \(response.text.prefix(400))")
            }
            text = try AnthropicProvider.parse(response.text)
        case .claudeCLI, .codexCLI, .geminiCLI:
            throw ReaderFailure("Internal: CLI provider handled elsewhere.")
        }
        onDelta(text)
        return AIResult(text: text, provider: provider, providerLabel: ProviderLabels.describe(provider, contextMode: prompt.contextMode), contextMode: prompt.contextMode)
    }

    public func resolve(_ purpose: AIPurpose, override: ProviderID?) -> ProviderID {
        if let override { return override }
        switch purpose {
        case .explainWord:
            return settings.lookupUsesDefault ? settings.defaultProvider : settings.lookupProvider
        default:
            return settings.defaultProvider
        }
    }

    private func runCLI(provider: ProviderID, book: BookText, focus: Focus?, purpose: AIPurpose, directory: String, originalBookPath: String?, fs: FileSystem, timeout: TimeInterval) throws -> AIResult {
        let executable: String?
        switch provider {
        case .claudeCLI: executable = settings.claudeCLIPath
        case .codexCLI: executable = settings.codexCLIPath
        case .geminiCLI: executable = settings.geminiCLIPath
        default: executable = nil
        }
        guard let executable, !executable.isEmpty else {
            throw ReaderFailure("\(provider.label) was not found. Set its path in Settings.")
        }
        let question: String
        switch purpose {
        case .ask(let value): question = value
        case .explainWord(let word): question = "In this passage, what does \"\(word)\" mean?"
        case .explainSimply: question = "Explain this passage in simpler words."
        case .summarizeSection: question = "Summarize this section."
        case .suggestNote: question = "Suggest a short reading note for this passage."
        }
        try CLIWorkspace.write(directory: directory, book: book, focus: focus, question: question, originalBookPath: originalBookPath, fs: fs)
        let invocation: CLIInvocation
        switch provider {
        case .claudeCLI:
            invocation = ClaudeCommand.invocation(executable: executable, prompt: CLIWorkspace.prompt, workingDirectory: directory)
        case .codexCLI:
            invocation = CodexCommand.invocation(executable: executable, prompt: CLIWorkspace.prompt, workingDirectory: directory, model: CodexCommand.resolveSolModel(home: NSHomeDirectory(), fs: fs))
        case .geminiCLI:
            invocation = GeminiCommand.invocation(executable: executable, prompt: CLIWorkspace.prompt, workingDirectory: directory)
        default:
            throw ReaderFailure("Not a terminal provider.")
        }
        var buffer = ""
        let result = try runner.run(invocation, timeout: timeout) { chunk in
            buffer += chunk
            self.onDelta(buffer)
        }
        if result.cancelled { throw ReaderFailure("Stopped.") }
        if result.timedOut { throw ReaderFailure("\(provider.label) timed out.") }
        let text: String
        switch provider {
        case .claudeCLI: text = try CLIOutput.parseClaude(result.stdout.isEmpty ? buffer : result.stdout)
        case .codexCLI: text = try CLIOutput.parseCodex(result.stdout.isEmpty ? buffer : result.stdout)
        case .geminiCLI: text = try CLIOutput.parseGemini(result.stdout.isEmpty ? buffer : result.stdout)
        default: text = ""
        }
        if result.exitCode != 0 && text.isEmpty {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReaderFailure(detail.isEmpty ? "\(provider.label) exited with status \(result.exitCode)." : detail)
        }
        return AIResult(text: text, provider: provider, providerLabel: ProviderLabels.describe(provider, contextMode: .wholeBook), contextMode: .wholeBook)
    }
}

final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public final class ProcessCommandRunner: CommandRunning {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning {
            kill(running.processIdentifier, SIGKILL)
            running.terminate()
        }
    }

    /// Enriches PATH for GUI-launched apps so `#!/usr/bin/env node` CLIs (like codex/gemini)
    /// and CLI helpers resolve Homebrew and user-local binaries reliably.
    public static func enrichedPATH(existing: String?, executable: String, home: String = NSHomeDirectory()) -> String {
        let trimmedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let execURL = URL(fileURLWithPath: executable)
        let resolvedURL = execURL.resolvingSymlinksInPath()
        var parts: [String] = [
            execURL.deletingLastPathComponent().path,
            resolvedURL.deletingLastPathComponent().path,
            "\(trimmedHome)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(trimmedHome)/.bun/bin",
            "\(trimmedHome)/.npm-global/bin",
        ]
        if let existing, !existing.isEmpty {
            parts.append(contentsOf: existing.split(separator: ":").map(String.init))
        }
        parts.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        var seen = Set<String>()
        var unique: [String] = []
        for dir in parts where !dir.isEmpty && seen.insert(dir).inserted {
            unique.append(dir)
        }
        return unique.joined(separator: ":")
    }

    public func run(_ invocation: CLIInvocation, timeout: TimeInterval, onStdout: @escaping (String) -> Void) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.enrichedPATH(existing: env["PATH"], executable: invocation.executable)
        process.environment = env
        if let directory = invocation.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        lock.lock()
        cancelled = false
        self.process = process
        lock.unlock()

        let outBox = LockedData()
        let errBox = LockedData()
        let group = DispatchGroup()
        group.enter()
        group.enter()
        DispatchQueue.global().async {
            let handle = stdout.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                outBox.append(chunk)
                if let text = String(data: chunk, encoding: .utf8) {
                    onStdout(text)
                }
            }
            group.leave()
        }
        DispatchQueue.global().async {
            let handle = stderr.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                errBox.append(chunk)
            }
            group.leave()
        }

        try process.run()
        let started = Date()
        while process.isRunning {
            if Date().timeIntervalSince(started) > timeout {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)

        lock.lock()
        let wasCancelled = cancelled
        self.process = nil
        lock.unlock()
        let output = outBox.string()
        let errors = errBox.string()
        let timedOut = !wasCancelled && Date().timeIntervalSince(started) > timeout
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: output,
            stderr: errors,
            timedOut: timedOut,
            cancelled: wasCancelled
        )
    }
}
