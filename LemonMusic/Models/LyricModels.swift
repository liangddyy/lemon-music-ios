// Derived from Cassette, licensed under MPL-2.0.

import Foundation

nonisolated struct LyricLine: Identifiable, Sendable, Equatable {
    let id: Int
    let time: TimeInterval?
    let text: String
}

nonisolated struct LyricDocument: Sendable, Equatable {
    static let empty = LyricDocument(lines: [])

    let lines: [LyricLine]

    init(rawValue: String) {
        let normalized = rawValue
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r", with: "")

        let yrcLines = Self.parseYRC(normalized)
        let parsed = yrcLines.isEmpty ? Self.parseLRC(normalized) : yrcLines
        let values = parsed.isEmpty ? Self.parsePlainText(normalized) : parsed.sorted {
            ($0.time ?? 0) < ($1.time ?? 0)
        }
        lines = values.enumerated().map { index, value in
            LyricLine(id: index, time: value.time, text: value.text)
        }
    }

    private init(lines: [LyricLine]) {
        self.lines = lines
    }

    var hasTimestamps: Bool {
        lines.contains { $0.time != nil }
    }

    func currentLineIndex(at position: TimeInterval) -> Int? {
        guard hasTimestamps else { return nil }
        var result: Int?
        for (index, line) in lines.enumerated() {
            guard let time = line.time else { continue }
            if time <= position + 0.08 {
                result = index
            } else {
                break
            }
        }
        return result
    }

    private struct ParsedLine {
        let time: TimeInterval?
        let text: String
    }

    private static func parseYRC(_ value: String) -> [ParsedLine] {
        let lineExpression = try? NSRegularExpression(pattern: #"^\[(\d+)\s*,\s*\d+\](.*)$"#)
        let wordExpression = try? NSRegularExpression(pattern: #"\(\d+\s*,\s*\d+(?:\s*,\s*-?\d+)?\)([^(]*)"#)
        guard let lineExpression, let wordExpression else { return [] }

        return value.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            let fullRange = NSRange(line.startIndex..., in: line)
            guard let match = lineExpression.firstMatch(in: line, range: fullRange),
                  let startRange = Range(match.range(at: 1), in: line),
                  let bodyRange = Range(match.range(at: 2), in: line),
                  let startMilliseconds = Double(line[startRange]) else { return nil }

            let body = String(line[bodyRange])
            let bodyRangeValue = NSRange(body.startIndex..., in: body)
            let text = wordExpression.matches(in: body, range: bodyRangeValue).compactMap { wordMatch -> String? in
                guard let range = Range(wordMatch.range(at: 1), in: body) else { return nil }
                return String(body[range])
            }.joined()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ParsedLine(time: startMilliseconds / 1000, text: trimmed)
        }
    }

    private static func parseLRC(_ value: String) -> [ParsedLine] {
        let tagExpression = try? NSRegularExpression(
            pattern: #"\[(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
        )
        guard let tagExpression else { return [] }
        var result: [ParsedLine] = []

        for rawLine in value.split(separator: "\n") {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.range(of: #"^\[(?:ti|ar|al|by|offset|id|length|ve):"#, options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            let fullRange = NSRange(line.startIndex..., in: line)
            let matches = tagExpression.matches(in: line, range: fullRange)
            guard let lastMatch = matches.last,
                  let textStart = Range(lastMatch.range, in: line)?.upperBound else { continue }
            let rawText = String(line[textStart...])
            let text = rawText
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            for match in matches {
                let hours = number(in: line, range: match.range(at: 1)) ?? 0
                let minutes = number(in: line, range: match.range(at: 2)) ?? 0
                let seconds = number(in: line, range: match.range(at: 3)) ?? 0
                let fraction = fraction(in: line, range: match.range(at: 4))
                result.append(ParsedLine(time: hours * 3600 + minutes * 60 + seconds + fraction, text: text))
            }
        }
        return result
    }

    private static func parsePlainText(_ value: String) -> [ParsedLine] {
        value.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  line.range(of: #"^\[(?:ti|ar|al|by|offset|id|length|ve):"#, options: [.regularExpression, .caseInsensitive]) == nil else {
                return nil
            }
            let cleaned = line
                .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : ParsedLine(time: nil, text: cleaned)
        }
    }

    private static func number(in value: String, range: NSRange) -> TimeInterval? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
        return Double(value[swiftRange])
    }

    private static func fraction(in value: String, range: NSRange) -> TimeInterval {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return 0 }
        let raw = String(value[swiftRange])
        return (Double(raw) ?? 0) / pow(10, Double(raw.count))
    }
}
