import Foundation

public enum TutorCommand: String, Equatable, Sendable {
    case learn
    case review
    case wrap

    public var slash: String { "/\(rawValue)" }
}

public struct TutorExchange: Equatable, Sendable {
    public var bookID: String
    public var chapter: Int?
    public var conceptIDs: [String]
    public var passageCharacterCount: Int
    public var date: String
    public var eventID: String

    public init(bookID: String, chapter: Int?, conceptIDs: [String], passageCharacterCount: Int, date: String, eventID: String) {
        self.bookID = bookID
        self.chapter = chapter
        self.conceptIDs = conceptIDs
        self.passageCharacterCount = passageCharacterCount
        self.date = date
        self.eventID = eventID
    }

    /// One JSON line. The passage text is intentionally absent.
    public func jsonLine() -> String {
        let concepts = conceptIDs.map { "\"\($0)\"" }.joined(separator: ",")
        let chapterField = chapter.map { ",\"chapter\":\($0)" } ?? ""
        return "{\"schema_version\":1,\"event_id\":\"\(eventID)\",\"date\":\"\(date)\",\"type\":\"reader_passage_question\",\"source\":\"reader_app\",\"book_id\":\"\(bookID)\"\(chapterField),\"concepts\":[\(concepts)],\"passage_chars\":\(passageCharacterCount)}"
    }
}

public enum TutorPrompt {
    public static func message(passage: String, chapter: Int?, chapterFile: String?, concepts: [Concept], question: String, command: TutorCommand?) -> String {
        var lines = [
            "You are the Socratic tutor described in CLAUDE.md. Ask one question at a time. Do not lecture.",
            "",
        ]
        if let command {
            lines.append("Skill: \(command.slash)")
            lines.append("")
        }
        if let chapter {
            lines.append("Chapter: \(chapter)")
        }
        if let chapterFile {
            lines.append("Chapter text: \(chapterFile)")
        }
        if !concepts.isEmpty {
            lines.append("Nearby concepts: \(concepts.map { "\($0.id) \($0.title)" }.joined(separator: "; "))")
        }
        lines.append("")
        lines.append("Passage:")
        lines.append(passage)
        lines.append("")
        if !question.isEmpty {
            lines.append("Reader's question: \(question)")
        }
        return lines.joined(separator: "\n")
    }
}

extension ClaudeCommand {
    /// Vault tutor: cwd is the book folder so CLAUDE.md and `.claude/skills` load.
    /// Session persistence uses `--resume` or `--continue`. Edit/Write stay inside learner/, learning/, and reviews/.
    public static let tutorWriteTools = "Read,Grep,Glob,Edit(learner/**),Edit(learning/**),Edit(reviews/**),Write(learner/**),Write(learning/**),Write(reviews/**)"

    public static func tutorInvocation(executable: String, prompt: String, workingDirectory: String, sessionID: String?) -> CLIInvocation {
        var arguments = [
            "--print",
            "--verbose",
            "--output-format", "stream-json",
            "--permission-mode", "dontAsk",
            "--tools", "Read,Grep,Glob,Edit,Write",
            "--allowedTools", tutorWriteTools,
        ]
        if let sessionID, !sessionID.isEmpty {
            arguments.append(contentsOf: ["--resume", sessionID])
        } else {
            arguments.append("--continue")
        }
        arguments.append(contentsOf: ["--", prompt])
        return CLIInvocation(executable: executable, arguments: arguments, workingDirectory: workingDirectory)
    }
}
