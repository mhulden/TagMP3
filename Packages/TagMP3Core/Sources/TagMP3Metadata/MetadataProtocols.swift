import Foundation
import TagLibSwift
import TagMP3Model

public protocol MetadataReading: Sendable {
    func readSnapshot(at url: URL) async throws -> TrackSnapshot
    func capabilities(for url: URL) async throws -> MetadataCapabilities
}

public protocol MetadataWriting: Sendable {
    func write(_ patch: TagPatch, to snapshot: TrackSnapshot) async throws -> WriteResult
}

public struct WriteResult: Equatable, Sendable {
    public let url: URL
    public let oldFingerprint: FileFingerprint
    public let newFingerprint: FileFingerprint?
    public let unsupportedFields: Set<FieldKey>
    public let warnings: [String]

    public init(url: URL, oldFingerprint: FileFingerprint, newFingerprint: FileFingerprint? = nil, unsupportedFields: Set<FieldKey> = [], warnings: [String] = []) {
        self.url = url
        self.oldFingerprint = oldFingerprint
        self.newFingerprint = newFingerprint
        self.unsupportedFields = unsupportedFields
        self.warnings = warnings
    }
}

public actor InMemoryMetadataStore: MetadataReading, MetadataWriting {
    private var snapshots: [URL: TrackSnapshot]

    public init(snapshots: [TrackSnapshot] = []) {
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.url, $0) })
    }

    public func readSnapshot(at url: URL) async throws -> TrackSnapshot {
        guard let snapshot = snapshots[url] else { throw MetadataError.unreadableFile(url.path) }
        return snapshot
    }

    public func capabilities(for url: URL) async throws -> MetadataCapabilities {
        _ = try await readSnapshot(at: url)
        return MetadataCapabilities(readableFields: Set(FieldKey.allCommon), writableFields: Set(FieldKey.allCommon), supportsArtwork: true, supportsMultipleArtwork: true)
    }

    public func write(_ patch: TagPatch, to snapshot: TrackSnapshot) async throws -> WriteResult {
        guard let current = snapshots[snapshot.url] else { throw MetadataError.unreadableFile(snapshot.url.path) }
        guard current.fingerprint == snapshot.fingerprint else { throw MetadataError.fingerprintMismatch }

        var fields = current.fields
        for (key, operation) in patch.fields {
            switch operation {
            case .keep: break
            case .set(let values): fields[key] = values
            case .remove: fields.removeValue(forKey: key)
            }
        }
        let artwork: [ArtworkDescriptor]
        switch patch.artwork {
        case .keep: artwork = current.artwork
        case .replace(let values): artwork = values
        case .remove: artwork = []
        }
        let updated = TrackSnapshot(id: current.id, url: current.url, fingerprint: current.fingerprint, fields: fields, artwork: artwork, audioProperties: current.audioProperties, warnings: current.warnings)
        snapshots[current.url] = updated
        return WriteResult(url: current.url, oldFingerprint: current.fingerprint, newFingerprint: updated.fingerprint)
    }
}

private extension FieldKey {
    static let allCommon: [FieldKey] = [.title, .artist, .album, .albumArtist, .trackNumber, .discNumber, .date, .genre, .comment, .composer]
}

/// Performs a metadata-only commit through a temporary sibling file.
public struct TagLibMetadataWriter: MetadataWriting, Sendable {
    public init() {}

    public func write(_ patch: TagPatch, to snapshot: TrackSnapshot) async throws -> WriteResult {
        try Task.checkCancellation()
        let fileExtension = snapshot.url.pathExtension.lowercased()
        guard TagLibMetadataReader.supportedExtensions.contains(fileExtension) else { throw MetadataError.unsupportedFormat }

        let currentFingerprint = try fingerprint(for: snapshot.url)
        guard currentFingerprint == snapshot.fingerprint else { throw MetadataError.fingerprintMismatch }
        let temporaryURL = snapshot.url
            .deletingLastPathComponent()
            .appendingPathComponent(".tagmp3-\(UUID().uuidString).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            let originalAttributes = try FileManager.default.attributesOfItem(atPath: snapshot.url.path)
            try FileManager.default.copyItem(at: snapshot.url, to: temporaryURL)
            if let permissions = originalAttributes[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporaryURL.path)
            }
            guard let file = AudioFile(path: temporaryURL.path), file.isValid else {
                throw MetadataError.unreadableFile("The temporary audio file could not be opened.")
            }
            var properties = file.properties
            for (key, operation) in patch.fields {
                switch operation {
                case .keep: break
                case .set(let values): properties[key.rawValue] = values.values
                case .remove: properties.removeValue(forKey: key.rawValue)
                }
            }
            let unsupported = file.setProperties(properties).keys.map { FieldKey($0) }
            guard unsupported.isEmpty else { throw MetadataError.unsupportedFields(Set(unsupported)) }
            switch patch.artwork {
            case .keep:
                break
            case .remove:
                guard file.setPictures([]) else {
                    throw MetadataError.verificationFailed("The artwork could not be removed.")
                }
            case .replace(let descriptors):
                let pictures = try descriptors.map { descriptor -> Picture in
                    guard let data = descriptor.encodedData, !data.isEmpty else {
                        throw MetadataError.verificationFailed("Artwork data was unavailable for writing.")
                    }
                    let type: Picture.PictureType = switch descriptor.pictureType {
                    case .frontCover: .frontCover
                    case .backCover: .backCover
                    case .other: .other
                    }
                    return Picture(data: data, mimeType: descriptor.mimeType, description: descriptor.description, pictureType: type)
                }
                guard file.setPictures(pictures) else {
                    throw MetadataError.verificationFailed("The artwork could not be written.")
                }
            }
            try file.save()
            try Task.checkCancellation()

            guard let reopened = AudioFile(path: temporaryURL.path), reopened.isValid else {
                throw MetadataError.verificationFailed("The written audio file could not be reopened.")
            }
            for (key, operation) in patch.fields {
                guard case .set(let expected) = operation else { continue }
                guard reopened.properties[key.rawValue] == expected.values else {
                    throw MetadataError.verificationFailed("The written value for \(key.rawValue) did not verify.")
                }
            }
            _ = try FileManager.default.replaceItemAt(snapshot.url, withItemAt: temporaryURL)
        } catch let error as MetadataError {
            throw error
        } catch {
            throw MetadataError.verificationFailed(error.localizedDescription)
        }

        let newFingerprint = try fingerprint(for: snapshot.url)
        return WriteResult(url: snapshot.url, oldFingerprint: snapshot.fingerprint, newFingerprint: newFingerprint)
    }

    private func fingerprint(for url: URL) throws -> FileFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let date = attributes[.modificationDate] as? Date else {
            throw MetadataError.unreadableFile("The file has no usable filesystem attributes.")
        }
        return FileFingerprint(byteCount: size.int64Value, modificationDate: date)
    }
}
