import Foundation
import TagMP3Model

public protocol FileAccessService: Sendable {
    func fingerprint(for url: URL) async throws -> FileFingerprint
    func replaceItem(at url: URL, with temporaryURL: URL) async throws
}

public actor InMemoryFileAccessService: FileAccessService {
    private var fingerprints: [URL: FileFingerprint]

    public init(fingerprints: [URL: FileFingerprint] = [:]) { self.fingerprints = fingerprints }

    public func fingerprint(for url: URL) async throws -> FileFingerprint {
        guard let fingerprint = fingerprints[url] else { throw MetadataError.unreadableFile(url.path) }
        return fingerprint
    }

    public func replaceItem(at url: URL, with temporaryURL: URL) async throws {
        guard fingerprints[url] != nil else { throw MetadataError.unreadableFile(url.path) }
        fingerprints[url] = fingerprints[temporaryURL]
    }
}
