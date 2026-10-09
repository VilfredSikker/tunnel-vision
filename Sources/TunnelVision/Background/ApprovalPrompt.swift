import Foundation

// MARK: - Model

/// One numbered choice of a Claude Code prompt.
struct ApprovalOption: Equatable, Sendable {
    /// The number shown before the label (1-based).
    let number: Int
    let label: String
    /// Indented lines under the option, such as an AskUserQuestion answer's
    /// explanation.
    let detail: [String]
    /// The option opens a text field ("Type something.", "Chat about this",
    /// "Tell Claude what to change"); a button cannot finish it, so the UI
    /// offers to open the pane instead.
    let needsTypedInput: Bool
}

/// A prompt read off an agent pane's screen.
struct ApprovalPrompt: Equatable, Sendable {
    /// What is asked about, e.g. "Bash command (unsandboxed)".
    let title: String
    /// The question line, e.g. "Do you want to proceed?".
    let question: String
    /// A few lines of context: the command, or an excerpt of the plan.
    let body: [String]
    let options: [ApprovalOption]
    /// Index into `options` of the one the `❯` cursor is on.
    let cursorIndex: Int
    /// Identifies this exact prompt: title, question, body and option
    /// labels. The body is part of it so two "Bash command · Yes / No"
    /// prompts for different commands never pass for each other.
    let fingerprint: String
}

/// A prompt shown by an agent working on a background task, waiting for
/// the user.
struct PendingApproval: Identifiable, Equatable, Sendable {
    let id: UUID
    let paneID: String
    let taskID: UUID
    let prompt: ApprovalPrompt

    var title: String { prompt.title }
    var question: String { prompt.question }
    var body: [String] { prompt.body }
    var options: [ApprovalOption] { prompt.options }
    var cursorIndex: Int { prompt.cursorIndex }
    var fingerprint: String { prompt.fingerprint }
}

// MARK: - Parser (pure, testable)

enum ApprovalParser {
    /// Labels that open a text field rather than answer, lowercased and
    /// without trailing punctuation.
    private static let typedInputLabels = ["type something", "chat about this", "tell claude what to change"]

    /// How many context lines a prompt keeps.
    static let maxBodyLines = 8

    private struct OptionLine {
        let number: Int
        let label: String
        /// Column of the number, which description lines indent past.
        let column: Int
        let isCursor: Bool
    }

    /// Reads a Claude Code prompt from a pane's visible text, or nil when
    /// the screen shows no numbered choice under a `❯` cursor.
    static func parse(_ text: String) -> ApprovalPrompt? {
        let lines = text.components(separatedBy: "\n").map { trimTrailing($0) }
        // The prompt sits at the bottom; numbered steps in a plan above it
        // never carry the cursor.
        guard let cursorLine = lines.indices.last(where: { optionLine(lines[$0])?.isCursor == true }) else { return nil }
        guard let block = optionBlock(around: cursorLine, in: lines) else { return nil }

        var options: [ApprovalOption] = []
        var cursorIndex = 0
        for entry in block.options {
            if entry.line.isCursor { cursorIndex = options.count }
            options.append(ApprovalOption(
                number: entry.line.number,
                label: entry.line.label,
                detail: entry.detail,
                needsTypedInput: needsTypedInput(entry.line.label)
            ))
        }

        // The question is the nearest text line above the options.
        var index = block.start - 1
        while index >= 0, isBlankOrSeparator(lines[index]) { index -= 1 }
        guard index >= 0 else { return nil }
        let questionIndex = index
        let question = clean(lines[questionIndex])

        // A permission prompt opens with a solid rule, then its title, then
        // the command; anything up to the question is context.
        let ruleIndex = (0..<questionIndex).last { isSolidRule(lines[$0]) }
        var title = ""
        var body: [String] = []
        if let ruleIndex,
           let titleIndex = (ruleIndex + 1..<questionIndex).first(where: { !isBlankOrSeparator(lines[$0]) }) {
            title = clean(lines[titleIndex])
            body = (titleIndex + 1..<questionIndex)
                .filter { !isBlankOrSeparator(lines[$0]) }
                .map { clean(lines[$0]) }
        } else {
            // A plan approval: the rule sits right above the question and
            // the plan itself is above the rule.
            let end = ruleIndex ?? questionIndex
            body = (0..<end)
                .filter { !isBlankOrSeparator(lines[$0]) }
                .map { clean(lines[$0]) }
                .suffix(maxBodyLines)
                .map { $0 }
            title = question.lowercased().contains("plan") ? "Plan approval" : "Claude needs input"
        }
        body = Array(body.prefix(maxBodyLines))

        let fingerprint = ([title, question] + body + options.map(\.label)).joined(separator: "\n")
        return ApprovalPrompt(
            title: title,
            question: question,
            body: body,
            options: options,
            cursorIndex: cursorIndex,
            fingerprint: fingerprint
        )
    }

    /// Keys that move the cursor from one option to another and choose it.
    /// Arrows, as the prompt itself says: "↑/↓ to
    /// navigate · Enter to select". Counted in options: the cursor skips
    /// separators and description lines.
    static func keys(from cursorIndex: Int, to targetIndex: Int) -> [String] {
        let steps = targetIndex - cursorIndex
        let arrow = steps > 0 ? "Down" : "Up"
        return Array(repeating: arrow, count: abs(steps)) + ["Enter"]
    }

    static func needsTypedInput(_ label: String) -> Bool {
        let normalized = label.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…:"))
        return typedInputLabels.contains { normalized.hasPrefix($0) }
    }

    // MARK: Internals

    /// The consecutive run of numbered options that holds the cursor line,
    /// with each option's description lines. A separator may sit between
    /// two options (AskUserQuestion puts one before "Chat about this").
    private static func optionBlock(
        around cursorLine: Int,
        in lines: [String]
    ) -> (start: Int, options: [(line: OptionLine, detail: [String])])? {
        // Walk up to the first option of the run.
        var start = cursorLine
        var probe = cursorLine - 1
        var expected = (optionLine(lines[cursorLine])?.number ?? 1) - 1
        while probe >= 0, expected >= 1 {
            if let option = optionLine(lines[probe]) {
                guard option.number == expected else { break }
                start = probe
                expected -= 1
            } else if !isSeparator(lines[probe]), !isDetail(lines[probe], under: optionLine(lines[start])) {
                break
            }
            probe -= 1
        }

        var options: [(line: OptionLine, detail: [String])] = []
        var index = start
        while index < lines.count {
            let line = lines[index]
            if let option = optionLine(line) {
                if let last = options.last, option.number != last.line.number + 1 { break }
                options.append((option, []))
            } else if isSeparator(line) {
                // Only between options: the run goes on if one follows.
                let next = (index + 1..<lines.count).first { !isSeparator(lines[$0]) }
                guard let next, optionLine(lines[next]) != nil else { break }
            } else if let last = options.last, isDetail(line, under: last.line) {
                options[options.count - 1].detail.append(clean(line))
            } else {
                break
            }
            index += 1
        }
        guard !options.isEmpty else { return nil }
        return (start, options)
    }

    /// `❯ 1. Yes` or `  2. No`, at any indent.
    private static func optionLine(_ line: String) -> OptionLine? {
        var rest = Substring(line)
        var column = 0
        while let first = rest.first, first == " " {
            rest = rest.dropFirst()
            column += 1
        }
        var isCursor = false
        if rest.first == "❯" {
            isCursor = true
            rest = rest.dropFirst()
            column += 1
            while let first = rest.first, first == " " {
                rest = rest.dropFirst()
                column += 1
            }
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.first == "." else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return OptionLine(number: number, label: label, column: column, isCursor: isCursor)
    }

    /// A description line is indented past its option's number.
    private static func isDetail(_ line: String, under option: OptionLine?) -> Bool {
        guard let option, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return leadingSpaces(line) > option.column
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    /// A line drawn only with box rules (`─` or `╌`).
    private static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" || $0 == "╌" || $0 == "━" }
    }

    /// The solid rule that opens a permission prompt (dashed ones frame the
    /// command inside it).
    private static func isSolidRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" || $0 == "━" }
    }

    private static func isBlankOrSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty || isSeparator(line)
    }

    /// Trimmed, without the checkbox glyph AskUserQuestion puts before its
    /// header.
    private static func clean(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for glyph in ["☐", "☒", "☑", "✔"] where text.hasPrefix(glyph) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func trimTrailing(_ line: String) -> String {
        var text = Substring(line)
        while let last = text.last, last == " " || last == "\r" || last == "\t" {
            text = text.dropLast()
        }
        return String(text)
    }
}
