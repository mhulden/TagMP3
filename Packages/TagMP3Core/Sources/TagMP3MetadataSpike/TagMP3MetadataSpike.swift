import Foundation
import TagLibSwift

/// The smallest project-owned seam around the candidate metadata engine.
/// Production domain types must replace this type before the engine is adopted.
public struct TagLibSpikeReport: Sendable, Equatable {
    public let dependencyRevision: String
    public let supportsPropertyMap: Bool
    public let supportsPictures: Bool

    public init(
        dependencyRevision: String = "530f2e1b78c0851a28fca16a279b649b17810029",
        supportsPropertyMap: Bool = true,
        supportsPictures: Bool = true
    ) {
        self.dependencyRevision = dependencyRevision
        self.supportsPropertyMap = supportsPropertyMap
        self.supportsPictures = supportsPictures
    }
}

public enum TagLibSpike {
    public static func report() -> TagLibSpikeReport {
        TagLibSpikeReport()
    }

    public static func canRoundTripSyntheticMemoryFile(
        _ data: Data,
        fileExtension: String
    ) -> Bool {
        guard let file = AudioFile(data: data, fileExtension: fileExtension) else {
            return false
        }
        // TagLib can create a memory-backed FileRef for extension-based input
        // even when it contains no decodable audio frames. Treat that as an
        // invalid candidate rather than allowing metadata-only writes.
        guard let audio = file.audioProperties,
              audio.lengthInMilliseconds > 0,
              audio.sampleRate > 0 else { return false }

        var properties = file.properties
        properties["TITLE"] = ["tagmp3 spike"]
        properties["CUSTOM_TEST_FIELD"] = ["one", "two"]
        let rejected = file.setProperties(properties)
        guard rejected.isEmpty else { return false }

        let picture = Picture(
            data: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            mimeType: "image/jpeg",
            description: "synthetic",
            pictureType: .frontCover
        )
        guard file.setPictures([picture]) else { return false }
        guard (try? file.save()) != nil else { return false }
        return (try? file.serialized()) != nil
    }
}
