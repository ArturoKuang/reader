import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
}

public enum CodexCommand {
    /// `codex exec` is the non-interactive command. `--sandbox read-only` is the default
    /// and is set explicitly. `--ask-for-approval never` keeps a scripted run from waiting
    /// on a person. `--skip-git-repo-check` is required because the temp folder is not a
    /// git checkout. `--ephemeral` skips session rollout files. `--json` is JSONL.
    /// `-C` is the documented short form of `--cd`. `--full-auto` is not used; current
    /// docs say it is no longer supported.
    public static func invocation(executable: String, prompt: String, workingDirectory: String) -> CLIInvocation {
        CLIInvocation(
            executable: executable,
            arguments: [
                "exec",
                "--sandbox", "read-only",
                "--ask-for-approval", "never",
                "--skip-git-repo-check",
                "--ephemeral",
                "--json",
                "-C", workingDirectory,
                prompt,
            ],
            workingDirectory: workingDirectory
        )
    }
}

public enum CLIOutput {
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
        }
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
        case .claudeCLI, .codexCLI:
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
            invocation = CodexCommand.invocation(executable: executable, prompt: CLIWorkspace.prompt, workingDirectory: directory)
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

    public func run(_ invocation: CLIInvocation, timeout: TimeInterval, onStdout: @escaping (String) -> Void) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if let directory = invocation.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
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
