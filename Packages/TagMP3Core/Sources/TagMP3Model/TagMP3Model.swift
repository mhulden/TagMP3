import Foundation

public struct TrackID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct FieldKey: Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ value: String) {
        rawValue = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public init(stringLiteral value: String) { self.init(value) }

    public static let title: Self = "TITLE"
    public static let artist: Self = "ARTIST"
    public static let album: Self = "ALBUM"
    public static let albumArtist: Self = "ALBUMARTIST"
    public static let trackNumber: Self = "TRACKNUMBER"
    public static let discNumber: Self = "DISCNUMBER"
    public static let date: Self = "DATE"
    public static let genre: Self = "GENRE"
    public static let comment: Self = "COMMENT"
    public static let composer: Self = "COMPOSER"
}

public struct FieldValues: Equatable, Hashable, Codable, Sendable {
    public let values: [String]

    public init(_ values: [String]) { self.values = values }
    public init(_ value: String) { self.init([value]) }
    public var isEmpty: Bool { values.isEmpty }
}

public struct ArtworkDescriptor: Equatable, Hashable, Codable, Sendable {
    public enum PictureType: String, Codable, Sendable { case frontCover, backCover, other }

    public let digest: String
    public let mimeType: String
    public let byteCount: Int
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let pictureType: PictureType
    public let description: String
    public let encodedData: Data?

    public init(
        digest: String,
        mimeType: String,
        byteCount: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        pictureType: PictureType = .frontCover,
        description: String = "",
        encodedData: Data? = nil
    ) {
        self.digest = digest
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pictureType = pictureType
        self.description = description
        self.encodedData = encodedData
    }
}

public struct AudioProperties: Equatable, Codable, Sendable {
    public let durationMilliseconds: Int
    public let codec: String?
    public let bitrate: Int?
    public let sampleRate: Int?
    public let channels: Int?
    public let bitsPerSample: Int?

    public init(durationMilliseconds: Int, codec: String? = nil, bitrate: Int? = nil, sampleRate: Int? = nil, channels: Int? = nil, bitsPerSample: Int? = nil) {
        self.durationMilliseconds = durationMilliseconds
        self.codec = codec
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }
}

public struct FileFingerprint: Equatable, Codable, Sendable {
    public let byteCount: Int64
    public let modificationDate: Date
    public let contentDigest: String?

    public init(byteCount: Int64, modificationDate: Date, contentDigest: String? = nil) {
        self.byteCount = byteCount
        self.modificationDate = modificationDate
        self.contentDigest = contentDigest
    }
}

public struct TrackSnapshot: Equatable, Codable, Sendable {
    public let id: TrackID
    public let url: URL
    public let fingerprint: FileFingerprint
    public let fields: [FieldKey: FieldValues]
    public let artwork: [ArtworkDescriptor]
    public let audioProperties: AudioProperties?
    public let warnings: [String]

    public init(id: TrackID, url: URL, fingerprint: FileFingerprint, fields: [FieldKey: FieldValues] = [:], artwork: [ArtworkDescriptor] = [], audioProperties: AudioProperties? = nil, warnings: [String] = []) {
        self.id = id
        self.url = url
        self.fingerprint = fingerprint
        self.fields = fields
        self.artwork = artwork
        self.audioProperties = audioProperties
        self.warnings = warnings
    }
}

public enum FieldOperation: Equatable, Codable, Sendable {
    case keep
    case set(FieldValues)
    case remove
}

public enum ArtworkOperation: Equatable, Codable, Sendable {
    case keep
    case replace([ArtworkDescriptor])
    case remove
}

public struct TagPatch: Equatable, Codable, Sendable {
    public var fields: [FieldKey: FieldOperation]
    public var artwork: ArtworkOperation

    public init(fields: [FieldKey: FieldOperation] = [:], artwork: ArtworkOperation = .keep) {
        self.fields = fields
        self.artwork = artwork
    }

    public static let empty = TagPatch()
}

public struct MetadataCapabilities: Equatable, Codable, Sendable {
    public let readableFields: Set<FieldKey>
    public let writableFields: Set<FieldKey>
    public let supportsArtwork: Bool
    public let supportsMultipleArtwork: Bool

    public init(readableFields: Set<FieldKey> = [], writableFields: Set<FieldKey> = [], supportsArtwork: Bool = false, supportsMultipleArtwork: Bool = false) {
        self.readableFields = readableFields
        self.writableFields = writableFields
        self.supportsArtwork = supportsArtwork
        self.supportsMultipleArtwork = supportsMultipleArtwork
    }
}

public enum MetadataError: Error, Equatable, Sendable {
    case unsupportedFormat
    case unreadableFile(String)
    case fingerprintMismatch
    case unsupportedFields(Set<FieldKey>)
    case verificationFailed(String)
    case cancelled
}

extension MetadataError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file format is not supported."
        case .unreadableFile(let message):
            return "The file could not be read: \(message)"
        case .fingerprintMismatch:
            return "The file changed externally; reload it before saving."
        case .unsupportedFields(let fields):
            return "These fields are not supported by the file: \(fields.map(\.rawValue).sorted().joined(separator: ", "))."
        case .verificationFailed(let message):
            return "The saved metadata could not be verified: \(message)"
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}
