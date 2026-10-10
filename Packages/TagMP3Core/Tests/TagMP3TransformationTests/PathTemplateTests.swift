import XCTest
import TagMP3Model
import TagMP3Transformations

final class PathTemplateTests: XCTestCase {
    func testRendersFieldsAndPadding() throws {
        let template = try PathTemplate("{album}/{track:02} - {title}")
        let snapshot = makeSnapshot(fields: [.album: FieldValues("Album"), .trackNumber: FieldValues("3"), .title: FieldValues("Song")])
        XCTAssertEqual(template.render(snapshot: snapshot), "Album/03 - Song")
    }

    func testRendersTrackNumeratorWhenValueIncludesTotal() throws {
        let padded = try PathTemplate("{track:02} - {title}")
        let unpadded = try PathTemplate("{track} - {title}")
        let snapshot = makeSnapshot(fields: [.trackNumber: FieldValues("12/23"), .title: FieldValues("Song")])
        XCTAssertEqual(padded.render(snapshot: snapshot), "12 - Song")
        XCTAssertEqual(unpadded.render(snapshot: snapshot), "12 - Song")
    }

    func testEscapesBracesAndOmitsEmptyOptionalSegment() throws {
        let template = try PathTemplate("{{disc}}[ - {disc:02}]/{{title}}")
        let snapshot = makeSnapshot(fields: [.title: FieldValues("Song")])
        XCTAssertEqual(template.render(snapshot: snapshot), "{disc}/{title}")
    }

    func testSanitizesEachPathComponent() throws {
        let template = try PathTemplate("{artist}/{title}")
        let snapshot = makeSnapshot(fields: [.artist: FieldValues("A:B"), .title: FieldValues("Song\\Live")])
        XCTAssertEqual(template.render(snapshot: snapshot), "A-B/Song-Live")
    }

    func testRejectsMalformedTemplates() {
        XCTAssertThrowsError(try PathTemplate("{title"))
        XCTAssertThrowsError(try PathTemplate("[ - {title}"))
        XCTAssertThrowsError(try PathTemplate("{missing}"))
        XCTAssertThrowsError(try PathTemplate("{track:0}"))
    }

    func testMatchesFieldsFromPathAndOptionalSegments() throws {
        let matcher = try PathTemplateMatcher("{album}/{track:02} - {title}[ - {artist}]")
        let values = try XCTUnwrap(matcher.match(relativePath: "Album/03 - Song - Artist.mp3"))
        XCTAssertEqual(values[.album]?.values, ["Album"])
        XCTAssertEqual(values[.trackNumber]?.values, ["03"])
        XCTAssertEqual(values[.title]?.values, ["Song"])
        XCTAssertEqual(values[.artist]?.values, ["Artist"])
    }

    func testMatcherReturnsNilForNonMatchingPath() throws {
        let matcher = try PathTemplateMatcher("{track:02} - {title}")
        XCTAssertNil(matcher.match(relativePath: "Song.mp3"))
    }

    func testMatcherUsesTrackNumberBeforeTotal() throws {
        let matcher = try PathTemplateMatcher("{track:02} - {title}")
        let values = try XCTUnwrap(matcher.match(relativePath: "12/23 - Song.mp3"))
        XCTAssertEqual(values[.trackNumber]?.values, ["12"])
        XCTAssertEqual(values[.title]?.values, ["Song"])
    }

    func testMatcherSupportsLiteralSuffixAfterTitle() throws {
        let matcher = try PathTemplateMatcher("{track:02} - {title} 14LUFS")
        let values = try XCTUnwrap(matcher.match(relativePath: "01 - Songname 14LUFS.flac"))
        XCTAssertEqual(values[.trackNumber]?.values, ["01"])
        XCTAssertEqual(values[.title]?.values, ["Songname"])
    }

    func testMatcherTreatsCommonDashCharactersAsEquivalent() throws {
        let matcher = try PathTemplateMatcher("{track:02} - {title} 14LUFS")
        let values = try XCTUnwrap(matcher.match(relativePath: "13 – Matkaa on ikuisuus 14LUFS.mp3"))
        XCTAssertEqual(values[.trackNumber]?.values, ["13"])
        XCTAssertEqual(values[.title]?.values, ["Matkaa on ikuisuus"])
    }

    func testFilenameTemplateMatchesBasenameWhenImportedPathIncludesFolder() throws {
        let matcher = try PathTemplateMatcher("{track:02} - {title} 14LUFS")
        let values = try XCTUnwrap(matcher.match(relativePath: "Some Album/14 - Symmetriaa 14LUFS.mp3"))
        XCTAssertEqual(values[.trackNumber]?.values, ["14"])
        XCTAssertEqual(values[.title]?.values, ["Symmetriaa"])
    }

    private func makeSnapshot(fields: [FieldKey: FieldValues]) -> TrackSnapshot {
        TrackSnapshot(
            id: TrackID(),
            url: URL(fileURLWithPath: "/tmp/original.mp3"),
            fingerprint: FileFingerprint(byteCount: 1, modificationDate: Date()),
            fields: fields
        )
    }
}
