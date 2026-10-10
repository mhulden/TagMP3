import Foundation
import XCTest
import TagMP3MetadataSpike

final class TagMP3MetadataSpikeTests: XCTestCase {
    func testCandidateEngineExposesRequiredSpikeSurfaces() {
        let report = TagLibSpike.report()
        XCTAssertEqual(report.dependencyRevision, "530f2e1b78c0851a28fca16a279b649b17810029")
        XCTAssertTrue(report.supportsPropertyMap)
        XCTAssertTrue(report.supportsPictures)
    }

    func testInvalidSyntheticInputIsRejected() {
        XCTAssertFalse(
            TagLibSpike.canRoundTripSyntheticMemoryFile(
                Data("not audio".utf8),
                fileExtension: "mp3"
            )
        )
    }
}
