import Foundation
import TagMP3Model

public struct PathOperationPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let source: URL
        public let destination: URL
        public let similarity: Double

        public init(source: URL, destination: URL, similarity: Double = 1) {
            self.source = source
            self.destination = destination
            self.similarity = similarity
        }

        public var isLowConfidence: Bool {
            source.standardizedFileURL != destination.standardizedFileURL && similarity < 0.35
        }
    }

    public let entries: [Entry]
    public let conflicts: [String]

    public var isValid: Bool { conflicts.isEmpty }

    public init(entries: [Entry], conflicts: [String] = []) {
        self.entries = entries
        self.conflicts = conflicts
    }
}

public struct PathOperationPlanner: Sendable {
    public init() {}

    public func plan(
        snapshots: [TrackSnapshot],
        template: String,
        organizeIntoFolders: Bool
    ) throws -> PathOperationPlan {
        let pathTemplate = try PathTemplate(template)
        let root = organizeIntoFolders ? commonDirectory(for: snapshots.map(\.url)) : nil
        let entries = snapshots.map { snapshot in
            let rendered = pathTemplate.render(snapshot: snapshot)
            let relativePath = organizeIntoFolders ? rendered : rendered.replacingOccurrences(of: "/", with: "-")
            let filename = appendExtension(relativePath, from: snapshot.url)
            let directory = root ?? snapshot.url.deletingLastPathComponent()
            return PathOperationPlan.Entry(
                source: snapshot.url.standardizedFileURL,
                destination: directory.appendingPathComponent(filename).standardizedFileURL,
                similarity: Self.filenameSimilarity(
                    source: snapshot.url.deletingPathExtension().lastPathComponent,
                    destination: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                )
            )
        }

        var conflicts: [String] = []
        let destinations = entries.map { $0.destination }
        if Set(destinations).count != destinations.count {
            conflicts.append("Two or more files have the same destination.")
        }
        let sources = Set(entries.map { $0.source })
        for entry in entries where entry.source != entry.destination {
            if FileManager.default.fileExists(atPath: entry.destination.path), !sources.contains(entry.destination) {
                conflicts.append("Destination already exists: (entry.destination.path)")
            }
        }
        if let root {
            let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
            for entry in entries where !entry.destination.path.hasPrefix(rootPath) {
                conflicts.append("Destination leaves the workspace root: " + entry.destination.path)
            }
        }
        return PathOperationPlan(entries: entries, conflicts: Array(Set(conflicts)).sorted())
    }

    private func appendExtension(_ path: String, from source: URL) -> String {
        let extensionName = source.pathExtension
        return path.lowercased().hasSuffix("." + extensionName.lowercased()) ? path : path + "." + extensionName
    }

    private static func filenameSimilarity(source: String, destination: String) -> Double {
        let left = normalizedFilename(source)
        let right = normalizedFilename(destination)
        guard left != right else { return 1 }
        guard left.count > 1, right.count > 1 else { return 0 }

        let leftBigrams = Set(zip(left, left.dropFirst()).map { String($0.0) + String($0.1) })
        let rightBigrams = Set(zip(right, right.dropFirst()).map { String($0.0) + String($0.1) })
        let common = leftBigrams.intersection(rightBigrams).count
        return Double(2 * common) / Double(leftBigrams.count + rightBigrams.count)
    }

    private static func normalizedFilename(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let withoutLeadingNumber = folded.replacingOccurrences(
            of: #"^\s*\d+(?:\s*[-_.]\s*|\s+)"#,
            with: "",
            options: .regularExpression
        )
        return withoutLeadingNumber.filter { $0.isLetter || $0.isNumber }
    }

    private func commonDirectory(for urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        let components = first.deletingLastPathComponent().standardizedFileURL.pathComponents
        let sharedCount = urls.dropFirst().reduce(components.count) { count, url in
            let other = url.deletingLastPathComponent().standardizedFileURL.pathComponents
            return min(count, zip(components, other).prefix { $0.0 == $0.1 }.count)
        }
        guard sharedCount > 0 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(sharedCount))))
    }
}
