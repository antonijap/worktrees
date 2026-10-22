import SwiftUI

/// Terminal-style colour for CI log lines in Why it failed: failures red, warnings amber,
/// passes green, file locations as links would be, quoted values like strings in code.
/// Colours come from Theme tokens, so contrast holds in light and dark.
enum LogHighlight {
    enum Role: Equatable {
        case plain, failure, warning, success, location, string, command, expected, received
    }

    struct Span: Equatable {
        let range: Range<String.Index>
        let role: Role
    }

    private static let failure = #/(?i)\b(error|errors|fail|failed|failure|fatal|panic|exception|traceback)\b|[✕✗×]|exit code [1-9]\d*/#
    private static let warning = #/(?i)\b(warning|warn|deprecated)\b/#
    private static let success = #/\b(PASS|passed|ok)\b|[✓✔]/#
    private static let location = #/[\w@./-]+\.[A-Za-z]{1,6}:\d+(?::\d+)?/#
    private static let string = #/"[^"\n]*"|'[^'\n]*'|`[^`\n]*`/#

    /// The whole line's role, from the strongest word in it: a failure beats a warning beats a pass.
    static func lineRole(_ line: String) -> Role {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Expected") { return .expected }
        if trimmed.hasPrefix("Received") { return .received }
        if trimmed.hasPrefix("$ ") || trimmed.hasPrefix("Run ") { return .command }
        if line.contains(failure) { return .failure }
        if line.contains(warning) { return .warning }
        if line.contains(success) { return .success }
        return .plain
    }

    /// File locations and quoted values, picked out inside a line whatever its role.
    static func spans(_ line: String) -> [Span] {
        var spans: [Span] = []
        for match in line.matches(of: location) { spans.append(Span(range: match.range, role: .location)) }
        for match in line.matches(of: string) where !spans.contains(where: { $0.range.overlaps(match.range) }) {
            spans.append(Span(range: match.range, role: .string))
        }
        return spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static func color(_ role: Role) -> Color {
        switch role {
        case .plain: Theme.codeText
        case .failure, .received: Theme.danger
        case .warning: Theme.warning
        case .success, .expected: Theme.success
        case .location: Theme.accent
        case .string: Theme.codeString
        case .command: Theme.codeFunction
        }
    }

    static func attributed(_ lines: [String]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var text = AttributedString(line)
            text.foregroundColor = color(lineRole(line))
            for span in spans(line) {
                let lower = line.distance(from: line.startIndex, to: span.range.lowerBound)
                let length = line.distance(from: span.range.lowerBound, to: span.range.upperBound)
                let start = text.index(text.startIndex, offsetByCharacters: lower)
                let end = text.index(start, offsetByCharacters: length)
                text[start..<end].foregroundColor = color(span.role)
            }
            result += text
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }
}
