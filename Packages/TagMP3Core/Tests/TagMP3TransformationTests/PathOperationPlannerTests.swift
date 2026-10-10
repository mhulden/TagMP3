import XCTest
import TagMP3Model
import TagMP3Transformations

final class PathOperationPlannerTests: XCTestCase {
    func testFolderPlanningUsesCommonRootAndPreservesExtensions() throws {
        let first = makeSnapshot(path: "/tmp/tagmp3-plan/one/a.mp3", title: "Song A", album: "Album")
        let second = makeSnapshot(path: "/tmp/tagmp3-plan/two/b.flac", title: "Song B", album: "Album")
        let plan = try PathOperationPlanner().plan(
            snapshots: [first, second],
            template: "{album}/{title}",
            organizeIntoFolders: true
        )
        XCTAssertTrue(plan.isValid)
        XCTAssertEqual(plan.entries[0].destination.path, "/tmp/tagmp3-plan/Album/Song A.mp3")
        XCTAssertEqual(plan.entries[1].destination.path, "/tmp/tagmp3-plan/Album/Song B.flac")
    }

    func testSameFolderModeDoesNotInterpretTemplateSlashAsFolder() throws {
        let snapshot = makeSnapshot(path: "/tmp/tagmp3-plan/a.mp3", title: "Song", album: "Album")
        let plan = try PathOperationPlanner().plan(snapshots: [snapshot], template: "{album}/{title}", organizeIntoFolders: false)
        XCTAssertEqual(plan.entries[0].destination.path, "/tmp/tagmp3-plan/Album-Song.mp3")
    }

    func testDuplicateDestinationsAreReported() throws {
        let first = makeSnapshot(path: "/tmp/tagmp3-plan/a.mp3", title: "Same", album: "Album")
        let second = makeSnapshot(path: "/tmp/tagmp3-plan/b.mp3", title: "Same", album: "Album")
        let plan = try PathOperationPlanner().plan(snapshots: [first, second], template: "{title}", organizeIntoFolders: false)
        XCTAssertFalse(plan.isValid)
        XCTAssertTrue(plan.conflicts.contains("Two or more files have the same destination."))
    }

    private func makeSnapshot(path: String, title: String, album: String) -> TrackSnapshot {
        TrackSnapshot(
            id: TrackID(),
            url: URL(fileURLWithPath: path),
            fingerprint: FileFingerprint(byteCount: 1, modificationDate: Date()),
            fields: [.title: FieldValues(title), .album: FieldValues(album)]
        )
    }
}
