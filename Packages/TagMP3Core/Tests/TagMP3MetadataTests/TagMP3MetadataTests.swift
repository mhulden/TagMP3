import XCTest
import TagMP3Model
import TagMP3Metadata

final class TagMP3MetadataTests: XCTestCase {
    func testFakeStoreAppliesOnlyExplicitOperations() async throws {
        let url = URL(fileURLWithPath: "/tmp/synthetic.mp3")
        let fingerprint = FileFingerprint(byteCount: 10, modificationDate: Date(timeIntervalSince1970: 1))
        let snapshot = TrackSnapshot(id: TrackID(), url: url, fingerprint: fingerprint, fields: [.title: FieldValues("Old"), .artist: FieldValues("Artist")])
        let store = InMemoryMetadataStore(snapshots: [snapshot])

        _ = try await store.write(TagPatch(fields: [.title: .set(FieldValues("New")), .artist: .keep]), to: snapshot)
        let updated = try await store.readSnapshot(at: url)
        XCTAssertEqual(updated.fields[.title], FieldValues("New"))
        XCTAssertEqual(updated.fields[.artist], FieldValues("Artist"))
    }

    func testFakeStoreRejectsStaleSnapshot() async throws {
        let url = URL(fileURLWithPath: "/tmp/stale.mp3")
        let fingerprint = FileFingerprint(byteCount: 10, modificationDate: Date(timeIntervalSince1970: 1))
        let current = TrackSnapshot(id: TrackID(), url: url, fingerprint: fingerprint)
        let stale = TrackSnapshot(id: current.id, url: url, fingerprint: FileFingerprint(byteCount: 20, modificationDate: fingerprint.modificationDate))
        let store = InMemoryMetadataStore(snapshots: [current])
        do {
            _ = try await store.write(.empty, to: stale)
            XCTFail("expected fingerprint mismatch")
        } catch let error as MetadataError {
            XCTAssertEqual(error, .fingerprintMismatch)
        }
    }
}
