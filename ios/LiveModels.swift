import Foundation
import ActivityKit
struct LessonActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable { var title: String; var room: String; var start: Date; var end: Date }
    var group: String
}

// Display-only normalization: raw classroom keys remain intact for server requests.
func cleanRoom(_ raw: String) -> String {
    let text = raw.replacingOccurrences(of: "(Основной)", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = #"(?i)(?:альфа|бета|гамма|дельта|омега|сигма)\s*\d+(?:[.,]\d+)+(?:[А-Яа-яA-Za-z](?![А-Яа-яA-Za-z]))?"#
    if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range, in: text) {
        return String(text[range])
    }
    guard text.count % 2 == 0 else { return text }
    let middle = text.index(text.startIndex, offsetBy: text.count / 2)
    return text[..<middle] == text[middle...] ? String(text[..<middle]) : text
}
