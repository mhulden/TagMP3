import Foundation
import TagMP3Model

public enum MetadataProviderID: String, Codable, Sendable {
    case musicBrainz
    case coverArtArchive
}

public struct ProviderApplication: Codable, Equatable, Sendable {
    public let name: String
    public let version: String
    public let contactURL: URL

    public init(name: String, version: String, contactURL: URL) {
        self.name = name
        self.version = version
        self.contactURL = contactURL
    }

    public var userAgent: String {
        "\(name)/\(version) (\(contactURL.absoluteString))"
    }
}

public struct ReleaseSearchQuery: Codable, Equatable, Sendable {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let barcode: String?
    public let limit: Int

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, barcode: String? = nil, limit: Int = 25) {
        self.title = title
        self.artist = artist
        self.album = album
        self.barcode = barcode
        self.limit = min(max(limit, 1), 100)
    }
}

public struct ProviderArtist: Codable, Equatable, Sendable {
    public let name: String
    public let sortName: String?
    public let identifier: String?

    public init(name: String, sortName: String? = nil, identifier: String? = nil) {
        self.name = name
        self.sortName = sortName
        self.identifier = identifier
    }
}

public struct ProviderTrack: Codable, Equatable, Sendable {
    public let position: Int
    public let title: String
    public let artists: [ProviderArtist]
    public let recordingIdentifier: String?
    public let lengthMilliseconds: Int?

    public init(position: Int, title: String, artists: [ProviderArtist] = [], recordingIdentifier: String? = nil, lengthMilliseconds: Int? = nil) {
        self.position = position
        self.title = title
        self.artists = artists
        self.recordingIdentifier = recordingIdentifier
        self.lengthMilliseconds = lengthMilliseconds
    }
}

public struct ProviderMedium: Codable, Equatable, Sendable {
    public let position: Int
    public let format: String?
    public let tracks: [ProviderTrack]

    public init(position: Int, format: String? = nil, tracks: [ProviderTrack]) {
        self.position = position
        self.format = format
        self.tracks = tracks
    }
}

public struct ReleaseCandidate: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let artists: [ProviderArtist]
    public let date: String?
    public let country: String?
    public let label: String?
    public let trackCount: Int?
    public let score: Int?

    public init(id: String, title: String, artists: [ProviderArtist] = [], date: String? = nil, country: String? = nil, label: String? = nil, trackCount: Int? = nil, score: Int? = nil) {
        self.id = id
        self.title = title
        self.artists = artists
        self.date = date
        self.country = country
        self.label = label
        self.trackCount = trackCount
        self.score = score
    }
}

public struct ReleaseDetails: Codable, Equatable, Sendable {
    public let candidate: ReleaseCandidate
    public let media: [ProviderMedium]
    public let barcode: String?

    public init(candidate: ReleaseCandidate, media: [ProviderMedium] = [], barcode: String? = nil) {
        self.candidate = candidate
        self.media = media
        self.barcode = barcode
    }
}

public struct ProviderArtwork: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let url: URL
    public let thumbnailURL: URL?
    public let types: [String]
    public let front: Bool
    public let back: Bool
    public let width: Int?
    public let height: Int?

    public init(id: String, url: URL, thumbnailURL: URL? = nil, types: [String] = [], front: Bool = false, back: Bool = false, width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.types = types
        self.front = front
        self.back = back
        self.width = width
        self.height = height
    }
}

public enum ProviderError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest(String)
    case unavailable(String)
    case rateLimited(retryAfterSeconds: Int?)
    case invalidResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .unavailable(let message):
            return message
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "The provider is rate-limiting requests. Try again in about \(retryAfterSeconds) seconds."
            }
            return "The provider is rate-limiting requests. Try again shortly."
        case .invalidResponse:
            return "The provider returned an invalid response."
        case .cancelled:
            return "The provider request was cancelled."
        }
    }
}

public protocol MetadataProvider: Sendable {
    var identifier: MetadataProviderID { get }
    func searchReleases(_ query: ReleaseSearchQuery) async throws -> [ReleaseCandidate]
    func releaseDetails(for identifier: String) async throws -> ReleaseDetails
    func artwork(for releaseIdentifier: String) async throws -> [ProviderArtwork]
}

public protocol ProviderResponseCache: Sendable {
    func response(for key: String) async -> Data?
    func insert(_ data: Data, for key: String, expiresAt: Date) async
    func removeAll() async
}

public actor InMemoryProviderResponseCache: ProviderResponseCache {
    private struct Entry: Sendable {
        let data: Data
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func response(for key: String) async -> Data? {
        guard let entry = entries[key] else { return nil }
        guard entry.expiresAt > now() else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.data
    }

    public func insert(_ data: Data, for key: String, expiresAt: Date) async {
        entries[key] = Entry(data: data, expiresAt: expiresAt)
    }

    public func removeAll() async {
        entries.removeAll()
    }
}

public actor RequestRateLimiter {
    private let minimumInterval: Duration
    private var lastRequest: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    public init(requestsPerSecond: Double = 1.0) {
        minimumInterval = .milliseconds(Int(1000 / max(requestsPerSecond, 0.01)))
    }

    public func waitForPermit() async throws {
        if let lastRequest {
            let elapsed = lastRequest.duration(to: clock.now)
            if elapsed < minimumInterval {
                try await clock.sleep(for: minimumInterval - elapsed)
            }
        }
        lastRequest = clock.now
    }
}
