import CryptoKit
import Foundation
import ImageIO
import TagLibSwift
import TagMP3Model

/// Reads supported audio files through the candidate engine and translates them into
/// project-owned values. TagLibSwift types do not escape this adapter.
public struct TagLibMetadataReader: MetadataReading, Sendable {
    private let idProvider: @Sendable (URL) -> TrackID

    public init(idProvider: @escaping @Sendable (URL) -> TrackID = { _ in TrackID() }) {
        self.idProvider = idProvider
    }

    public func readSnapshot(at url: URL) async throws -> TrackSnapshot {
        try Task.checkCancellation()
        let fileExtension = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else { throw MetadataError.unsupportedFormat }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw MetadataError.unreadableFile(error.localizedDescription)
        }
        guard let byteCount = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else {
            throw MetadataError.unreadableFile("The file has no usable filesystem attributes.")
        }

        guard let file = AudioFile(path: url.path),
              file.isValid,
              let audio = file.audioProperties,
              audio.lengthInMilliseconds > 0,
              audio.sampleRate > 0 else {
            throw MetadataError.unreadableFile("TagLib could not decode a valid \(fileExtension.uppercased()) stream.")
        }

        var fields: [FieldKey: FieldValues] = [:]
        for (key, values) in file.properties where !values.isEmpty {
            fields[FieldKey(key)] = FieldValues(values)
        }

        let artwork = file.pictures.map { picture in
            let imageSource = CGImageSourceCreateWithData(picture.data as CFData, nil)
            let properties = imageSource.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int
            let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int
            return ArtworkDescriptor(
                digest: SHA256.hash(data: picture.data).map { String(format: "%02x", $0) }.joined(),
                mimeType: picture.mimeType,
                byteCount: picture.data.count,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                pictureType: picture.pictureType == .frontCover ? .frontCover : .other,
                description: picture.description,
                encodedData: picture.data
            )
        }

        let properties = TagMP3Model.AudioProperties(
            durationMilliseconds: audio.lengthInMilliseconds,
            codec: fileExtension.uppercased(),
            bitrate: audio.bitrate,
            sampleRate: audio.sampleRate,
            channels: audio.channels,
            bitsPerSample: audio.bitsPerSample
        )
        let fingerprint = FileFingerprint(byteCount: byteCount.int64Value, modificationDate: modificationDate)
        return TrackSnapshot(
            id: idProvider(url),
            url: url,
            fingerprint: fingerprint,
            fields: fields,
            artwork: artwork,
            audioProperties: properties
        )
    }

    public func capabilities(for url: URL) async throws -> MetadataCapabilities {
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else { throw MetadataError.unsupportedFormat }
        _ = try await readSnapshot(at: url)
        return MetadataCapabilities(
            readableFields: Set([.title, .artist, .album, .albumArtist, .trackNumber, .discNumber, .date, .genre, .comment, .composer]),
            writableFields: Set([.title, .artist, .album, .albumArtist, .trackNumber, .discNumber, .date, .genre, .comment, .composer]),
            supportsArtwork: true,
            supportsMultipleArtwork: true
        )
    }

    public static let supportedExtensions: Set<String> = [
        "mp3", "flac", "ogg", "oga", "opus", "m4a", "mp4", "alac",
        "wav", "aiff", "aif", "ape", "wv", "dsf"
    ]
}
