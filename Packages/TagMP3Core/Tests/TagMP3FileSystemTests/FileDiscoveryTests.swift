import XCTest
import TagMP3FileSystem

final class FileDiscoveryTests: XCTestCase {
    func testDiscoveryFindsOnlySupportedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0]).write(to: root.appendingPathComponent("one.mp3"))
        try Data([0]).write(to: root.appendingPathComponent("ignore.txt"))
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0]).write(to: nested.appendingPathComponent("two.MP3"))

        var files: [URL] = []
        for await event in FileDiscovery().events(for: root) {
            if case .file(let url) = event { files.append(url) }
        }
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(["one.mp3", "two.MP3"]))
    }
}
