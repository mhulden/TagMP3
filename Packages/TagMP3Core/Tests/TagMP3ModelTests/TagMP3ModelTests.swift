import XCTest
import TagMP3Model

final class TagMP3ModelTests: XCTestCase {
    func testFieldKeysNormalizeWithoutFlatteningValues() {
        XCTAssertEqual(FieldKey(" title ").rawValue, "TITLE")
        XCTAssertEqual(FieldValues(["one", "two"]).values, ["one", "two"])
    }

    func testPatchKeepsSetAndRemovesExplicitly() throws {
        let patch = TagPatch(fields: [.title: .keep, .artist: .set(FieldValues("A")), .comment: .remove])
        XCTAssertEqual(patch.fields[.title], .keep)
        XCTAssertEqual(patch.fields[.artist], .set(FieldValues("A")))
        XCTAssertEqual(patch.fields[.comment], .remove)
        XCTAssertTrue(try JSONEncoder().encode(patch).count > 0)
    }
}
