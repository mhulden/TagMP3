import XCTest
import TagMP3Model
import TagMP3FileSystem

final class TagMP3FileSystemTests: XCTestCase {
    func testFakeFileAccessReturnsInjectedFingerprint() async throws {
        let url = URL(fileURLWithPath: "/tmp/file.mp3")
        let fingerprint = FileFingerprint(byteCount: 42, modificationDate: Date(timeIntervalSince1970: 1))
        let service = InMemoryFileAccessService(fingerprints: [url: fingerprint])
        let actual = try await service.fingerprint(for: url)
        XCTAssertEqual(actual, fingerprint)
    }
}
