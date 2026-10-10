import XCTest
import TagMP3Metadata
import TagMP3Model

final class TagLibMetadataReaderTests: XCTestCase {
    func testReaderRejectsUnsupportedExtensionWithoutTouchingTheFile() async {
        let reader = TagLibMetadataReader()
        do {
            _ = try await reader.readSnapshot(at: URL(fileURLWithPath: "/tmp/example.xyz"))
            XCTFail("expected unsupported format")
        } catch let error as MetadataError {
            XCTAssertEqual(error, .unsupportedFormat)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testReaderRejectsMalformedMP3() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not an mp3".utf8).write(to: url)
        let reader = TagLibMetadataReader()
        do {
            _ = try await reader.readSnapshot(at: url)
            XCTFail("expected malformed file failure")
        } catch let error as MetadataError {
            if case .unreadableFile = error { } else { XCTFail("unexpected error: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOggAndOpusExtensionsReachTheFormatReader() async {
        let reader = TagLibMetadataReader()
        for fileExtension in ["ogg", "oga", "opus"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try? Data("not audio".utf8).write(to: url)
            do {
                _ = try await reader.readSnapshot(at: url)
                XCTFail("expected malformed \(fileExtension) failure")
            } catch let error as MetadataError {
                guard case .unreadableFile(let message) = error else {
                    XCTFail("unexpected error for \(fileExtension): \(error)")
                    continue
                }
                XCTAssertTrue(message.contains(fileExtension.uppercased()))
            } catch {
                XCTFail("unexpected error for \(fileExtension): \(error)")
            }
        }
    }

    func testM4AAndMP4ExtensionsReachTheFormatReader() async {
        let reader = TagLibMetadataReader()
        for fileExtension in ["m4a", "mp4", "alac"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try? Data("not audio".utf8).write(to: url)
            do {
                _ = try await reader.readSnapshot(at: url)
                XCTFail("expected malformed \(fileExtension) failure")
            } catch let error as MetadataError {
                guard case .unreadableFile(let message) = error else {
                    XCTFail("unexpected error for \(fileExtension): \(error)")
                    continue
                }
                XCTAssertTrue(message.contains(fileExtension.uppercased()))
            } catch {
                XCTFail("unexpected error for \(fileExtension): \(error)")
            }
        }
    }

    func testWAVAndAIFFExtensionsReachTheFormatReader() async {
        let reader = TagLibMetadataReader()
        for fileExtension in ["wav", "aiff", "aif"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try? Data("not audio".utf8).write(to: url)
            do {
                _ = try await reader.readSnapshot(at: url)
                XCTFail("expected malformed \(fileExtension) failure")
            } catch let error as MetadataError {
                guard case .unreadableFile(let message) = error else {
                    XCTFail("unexpected error for \(fileExtension): \(error)")
                    continue
                }
                XCTAssertTrue(message.contains(fileExtension.uppercased()))
            } catch {
                XCTFail("unexpected error for \(fileExtension): \(error)")
            }
        }
    }

    func testAPEWavPackAndDSFExtensionsReachTheFormatReader() async {
        let reader = TagLibMetadataReader()
        for fileExtension in ["ape", "wv", "dsf"] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            defer { try? FileManager.default.removeItem(at: url) }
            try? Data("not audio".utf8).write(to: url)
            do {
                _ = try await reader.readSnapshot(at: url)
                XCTFail("expected malformed \(fileExtension) failure")
            } catch let error as MetadataError {
                guard case .unreadableFile(let message) = error else {
                    XCTFail("unexpected error for \(fileExtension): \(error)")
                    continue
                }
                XCTAssertTrue(message.contains(fileExtension.uppercased()))
            } catch {
                XCTFail("unexpected error for \(fileExtension): \(error)")
            }
        }
    }
}
