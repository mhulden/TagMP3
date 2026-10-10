import Foundation
import TagMP3Model

public struct PathTemplateMatcher: Sendable {
    public let template: String
    private let expression: NSRegularExpression
    private let capturedKeys: [FieldKey]

    public init(_ template: String) throws {
        _ = try PathTemplate(template)
        self.template = template
        var compiler = MatcherCompiler(source: template)
        let compiled = try compiler.compile(until: nil)
        expression = try NSRegularExpression(pattern: "^(?:" + compiled.pattern + ")$")
        capturedKeys = compiled.keys
    }

    public func match(relativePath: String) -> [FieldKey: FieldValues]? {
        let pathWithoutExtension = removingExtension(from: relativePath)
        let filenameWithoutExtension = pathWithoutExtension.split(separator: "/").last.map(String.init) ?? pathWithoutExtension
        let candidates: [String]
        if template.contains("/") {
            candidates = [pathWithoutExtension, relativePath]
        } else {
            // Imported files can retain their source folder in relativePath
            // (for example, "Album/01 - Song.mp3"). A filename-only
            // template must match the basename, not the folder prefix.
            // Try the full path first because a slash can be meaningful in a
            // numeric field such as "12/23" (track/total). Fall back to the
            // basename for an ordinary imported folder prefix.
            candidates = [pathWithoutExtension, relativePath, filenameWithoutExtension]
        }
        let matched = candidates.compactMap { candidate -> (String, NSTextCheckingResult)? in
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let result = expression.firstMatch(in: candidate, range: range) else { return nil }
            return (candidate, result)
        }.first
        guard let (matchedPath, result) = matched else { return nil }
        var values: [FieldKey: FieldValues] = [:]
        for (offset, key) in capturedKeys.enumerated() {
            let captureRange = result.range(at: offset + 1)
            guard captureRange.location != NSNotFound,
                  let swiftRange = Range(captureRange, in: matchedPath) else { continue }
            values[key] = FieldValues(String(matchedPath[swiftRange]))
        }
        return values
    }

    private func removingExtension(from path: String) -> String {
        guard let slash = path.lastIndex(of: "/"),
              let dot = path[slash...].lastIndex(of: "."), dot > slash else {
            guard let dot = path.lastIndex(of: ".") else { return path }
            return String(path[..<dot])
        }
        return String(path[..<dot])
    }
}

private struct CompiledPattern {
    let pattern: String
    let keys: [FieldKey]
}

private struct MatcherCompiler {
    let source: [Character]
    var index = 0

    init(source: String) { self.source = Array(source) }

    mutating func compile(until terminator: Character?) throws -> CompiledPattern {
        var pattern = ""
        var keys: [FieldKey] = []
        while index < source.count {
            let character = source[index]
            if character == terminator {
                index += 1
                return CompiledPattern(pattern: pattern, keys: keys)
            }
            if character == "{" {
                if peek(1) == "{" { pattern += NSRegularExpression.escapedPattern(for: "{"); index += 2; continue }
                index += 1
                guard let close = source[index...].firstIndex(of: "}") else { throw PathTemplate.TemplateError.unterminatedPlaceholder }
                let token = String(source[index..<close])
                index = close + 1
                let field = try fieldInfo(token)
                keys.append(field.key)
                pattern += field.numeric ? "([0-9]+)(?:/[0-9]+)?" : "([^/]+?)"
                continue
            }
            if character == "}" && peek(1) == "}" {
                pattern += NSRegularExpression.escapedPattern(for: "}")
                index += 2
                continue
            }
            if character == "[" {
                index += 1
                let child = try compile(until: "]")
                pattern += "(?:" + child.pattern + ")?"
                keys.append(contentsOf: child.keys)
                continue
            }
            // Filenames commonly use an en dash or em dash where a template
            // was typed with a hyphen-minus. Treat the three dash forms as
            // equivalent in literal template text while keeping all other
            // characters exact.
            if character == "-" || character == "–" || character == "—" {
                pattern += "[-–—]"
            } else {
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        if terminator != nil { throw PathTemplate.TemplateError.unmatchedOptionalSegment }
        return CompiledPattern(pattern: pattern, keys: keys)
    }

    private func peek(_ offset: Int) -> Character? {
        let position = index + offset
        return position < source.count ? source[position] : nil
    }

    private func fieldInfo(_ token: String) throws -> (key: FieldKey, numeric: Bool) {
        let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let names: [String: FieldKey] = [
            "title": .title, "artist": .artist, "album": .album,
            "albumartist": .albumArtist, "track": .trackNumber,
            "disc": .discNumber, "date": .date, "genre": .genre,
            "comment": .comment, "composer": .composer
        ]
        let name = String(parts[0]).lowercased()
        guard let key = names[name] else { throw PathTemplate.TemplateError.unknownPlaceholder(name) }
        if parts.count == 1 { return (key, false) }
        let width = String(parts[1])
        guard let value = Int(width), value > 0, value <= 20 else {
            throw PathTemplate.TemplateError.invalidWidth(width)
        }
        return (key, key == .trackNumber || key == .discNumber)
    }
}
