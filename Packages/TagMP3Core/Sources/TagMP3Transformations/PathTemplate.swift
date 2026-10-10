import Foundation
import TagMP3Model

public struct PathTemplate: Equatable, Sendable {
    public enum TemplateError: Error, Equatable, Sendable, LocalizedError {
        case emptyTemplate
        case unterminatedPlaceholder
        case unknownPlaceholder(String)
        case invalidWidth(String)
        case unmatchedOptionalSegment

        public var errorDescription: String? {
            switch self {
            case .emptyTemplate: return "The template cannot be empty."
            case .unterminatedPlaceholder: return "A placeholder is missing its closing brace."
            case .unknownPlaceholder(let value): return "Unknown placeholder: \(value)."
            case .invalidWidth(let value): return "Invalid placeholder width: \(value)."
            case .unmatchedOptionalSegment: return "An optional segment is missing its closing bracket."
            }
        }
    }

    fileprivate indirect enum Node: Equatable, Sendable {
        case text(String)
        case field(FieldKey, width: Int?)
        case optional([Node])
    }

    private let nodes: [Node]

    public init(_ source: String) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TemplateError.emptyTemplate
        }
        var parser = Parser(source: source)
        nodes = try parser.parseNodes(until: nil)
    }

    public func render(snapshot: TrackSnapshot, sanitizePath: Bool = true) -> String {
        let rendered = render(nodes, snapshot: snapshot)
        let components = rendered.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let safe = components.map { sanitizePath ? Self.sanitizeComponent($0) : $0 }
        let result = safe.joined(separator: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? snapshot.url.deletingPathExtension().lastPathComponent : result
    }

    private func render(_ nodes: [Node], snapshot: TrackSnapshot) -> String {
        nodes.map { node in
            switch node {
            case .text(let value): return value
            case .field(let key, let width):
                let value = snapshot.fields[key]?.values.first ?? (key == .title ? snapshot.url.deletingPathExtension().lastPathComponent : "")
                let renderedValue: String
                if key == .trackNumber || key == .discNumber {
                    renderedValue = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? value
                } else {
                    renderedValue = value
                }
                guard let width, let number = Int(renderedValue), number >= 0 else { return renderedValue }
                return String(format: "%0*d", width, number)
            case .optional(let children):
                return hasValue(in: children, snapshot: snapshot) ? render(children, snapshot: snapshot) : ""
            }
        }.joined()
    }

    private func hasValue(in nodes: [Node], snapshot: TrackSnapshot) -> Bool {
        nodes.contains { node in
            switch node {
            case .text: return false
            case .field(let key, _):
                return !(snapshot.fields[key]?.values.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .optional(let children): return hasValue(in: children, snapshot: snapshot)
            }
        }
    }

    private static func sanitizeComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: ":\\")
        let sanitized = value.components(separatedBy: invalid).joined(separator: "-")
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct Parser {
    let source: [Character]
    var index = 0

    init(source: String) { self.source = Array(source) }

    mutating func parseNodes(until terminator: Character?) throws -> [PathTemplate.Node] {
        var nodes: [PathTemplate.Node] = []
        var text = ""
        func flush(_ text: inout String, _ nodes: inout [PathTemplate.Node]) {
            guard !text.isEmpty else { return }
            nodes.append(.text(text))
            text.removeAll(keepingCapacity: true)
        }

        while index < source.count {
            let character = source[index]
            if character == terminator {
                flush(&text, &nodes)
                index += 1
                return nodes
            }
            if character == "{" {
                if peek(1) == "{" { text.append("{"); index += 2; continue }
                flush(&text, &nodes)
                index += 1
                guard let close = source[index...].firstIndex(of: "}") else { throw PathTemplate.TemplateError.unterminatedPlaceholder }
                let token = String(source[index..<close])
                index = close + 1
                nodes.append(try parseField(token))
                continue
            }
            if character == "}" && peek(1) == "}" { text.append("}"); index += 2; continue }
            if character == "[" {
                flush(&text, &nodes)
                index += 1
                nodes.append(.optional(try parseNodes(until: "]")))
                continue
            }
            text.append(character)
            index += 1
        }
        if terminator != nil { throw PathTemplate.TemplateError.unmatchedOptionalSegment }
        flush(&text, &nodes)
        return nodes
    }

    private func peek(_ offset: Int) -> Character? {
        let position = index + offset
        return position < source.count ? source[position] : nil
    }

    private func parseField(_ token: String) throws -> PathTemplate.Node {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0]).lowercased()
        let known: [String: FieldKey] = [
            "title": .title, "artist": .artist, "album": .album,
            "albumartist": .albumArtist, "track": .trackNumber,
            "disc": .discNumber, "date": .date, "genre": .genre,
            "comment": .comment, "composer": .composer
        ]
        guard let key = known[name] else { throw PathTemplate.TemplateError.unknownPlaceholder(name) }
        guard parts.count == 2 else { return .field(key, width: nil) }
        let widthText = String(parts[1])
        guard let width = Int(widthText), width > 0, width <= 20 else {
            throw PathTemplate.TemplateError.invalidWidth(widthText)
        }
        return .field(key, width: width)
    }
}
