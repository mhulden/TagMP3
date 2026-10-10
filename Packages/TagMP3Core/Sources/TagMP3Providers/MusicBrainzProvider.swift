import Foundation

public protocol ProviderHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionProviderHTTPClient: ProviderHTTPClient, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
            return (data, response.statusCode)
        } catch is CancellationError {
            throw ProviderError.cancelled
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.unavailable(error.localizedDescription)
        }
    }
}

public struct MusicBrainzProvider: MetadataProvider, Sendable {
    public let identifier: MetadataProviderID = .musicBrainz

    private let application: ProviderApplication
    private let httpClient: any ProviderHTTPClient
    private let cache: any ProviderResponseCache
    private let limiter: RequestRateLimiter
    private let baseURL: URL
    private let cacheLifetime: TimeInterval

    public init(
        application: ProviderApplication,
        httpClient: any ProviderHTTPClient = URLSessionProviderHTTPClient(),
        cache: any ProviderResponseCache = InMemoryProviderResponseCache(),
        limiter: RequestRateLimiter = RequestRateLimiter(),
        baseURL: URL = URL(string: "https://musicbrainz.org/ws/2")!,
        cacheLifetime: TimeInterval = 86_400
    ) {
        self.application = application
        self.httpClient = httpClient
        self.cache = cache
        self.limiter = limiter
        self.baseURL = baseURL
        self.cacheLifetime = cacheLifetime
    }

    public func searchReleases(_ query: ReleaseSearchQuery) async throws -> [ReleaseCandidate] {
        let terms = Self.makeSearchTerms(query, includeRecordingTitle: true)
        guard !terms.isEmpty else { throw ProviderError.invalidRequest("Enter at least one search term.") }

        let strictResults = try await searchReleases(terms: terms, limit: query.limit)
        guard let album = query.album, !album.isEmpty else {
            return strictResults
        }

        let strictMatch = strictResults.contains {
            Self.searchComparable($0.title) == Self.searchComparable(album)
        }
        guard !strictMatch else { return strictResults }

        // A recording title can be absent from a release's indexed search data,
        // even when the release and artist are an excellent match. Keep the
        // track title useful as a first pass, then broaden without it. This
        // also protects against capitalization and punctuation differences.
        let fallbackTerms = Self.makeSearchTerms(query, includeRecordingTitle: false)
        let fallbackResults = try await searchReleases(terms: fallbackTerms, limit: query.limit)
        var merged = strictResults
        for result in fallbackResults where !merged.contains(where: { $0.id == result.id }) {
            merged.append(result)
        }
        return merged
    }

    public func releaseDetails(for identifier: String) async throws -> ReleaseDetails {
        guard Self.isMBID(identifier) else { throw ProviderError.invalidRequest("The release identifier is not a valid MusicBrainz ID.") }
        let url = try makeURL(path: "release/\(identifier)", queryItems: [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: "artist-credits+media+recordings+labels")
        ])
        let response = try await request(url)
        let decoded = try JSONDecoder().decode(ReleaseResponse.self, from: response)
        let candidate = Self.makeCandidate(decoded)
        let media = decoded.media?.map(Self.makeMedium) ?? []
        return ReleaseDetails(candidate: candidate, media: media, barcode: decoded.barcode)
    }

    public func artwork(for releaseIdentifier: String) async throws -> [ProviderArtwork] {
        guard Self.isMBID(releaseIdentifier) else { throw ProviderError.invalidRequest("The release identifier is not a valid MusicBrainz ID.") }
        let url = URL(string: "https://coverartarchive.org/release/\(releaseIdentifier)")!
        let response = try await request(url)
        let decoded = try JSONDecoder().decode(ArtworkResponse.self, from: response)
        return decoded.images.map {
            ProviderArtwork(
                id: String($0.id),
                url: $0.image,
                thumbnailURL: $0.thumbnails?.large ?? $0.thumbnails?.small,
                types: $0.types ?? [],
                front: $0.front ?? false,
                back: $0.back ?? false,
                width: $0.width,
                height: $0.height
            )
        }
    }

    private func request(_ url: URL) async throws -> Data {
        let key = url.absoluteString
        if let cached = await cache.response(for: key) { return cached }
        try await limiter.waitForPermit()
        var request = URLRequest(url: url)
        request.setValue(application.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await httpClient.data(for: request)
        guard (200..<300).contains(status) else {
            if status == 429 || status == 503 { throw ProviderError.rateLimited(retryAfterSeconds: nil) }
            throw ProviderError.unavailable("The provider returned HTTP \(status).")
        }
        await cache.insert(data, for: key, expiresAt: Date().addingTimeInterval(cacheLifetime))
        return data
    }

    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidRequest("Could not construct the provider URL.")
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw ProviderError.invalidRequest("Could not construct the provider URL.") }
        return url
    }

    private func searchReleases(terms: [String], limit: Int) async throws -> [ReleaseCandidate] {
        let url = try makeURL(path: "release", queryItems: [
            URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit))
        ])
        let response = try await request(url)
        let decoded = try JSONDecoder().decode(ReleaseSearchResponse.self, from: response)
        return decoded.releases.map(Self.makeCandidate)
    }

    private static func makeSearchTerms(_ query: ReleaseSearchQuery, includeRecordingTitle: Bool) -> [String] {
        var terms: [String] = []
        if includeRecordingTitle, let title = query.title, !title.isEmpty {
            terms.append("recording:\"\(escapeQuery(title))\"")
        }
        if let artist = query.artist, !artist.isEmpty { terms.append("artist:\"\(escapeQuery(artist))\"") }
        if let album = query.album, !album.isEmpty { terms.append("release:\"\(escapeQuery(album))\"") }
        if let barcode = query.barcode, !barcode.isEmpty { terms.append("barcode:\"\(escapeQuery(barcode))\"") }
        return terms
    }

    private static func searchComparable(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: .punctuationCharacters)
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func escapeQuery(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func isMBID(_ value: String) -> Bool {
        value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$", options: .regularExpression) != nil
    }

    private static func makeCandidate(_ value: ReleaseResponse) -> ReleaseCandidate {
        ReleaseCandidate(id: value.id, title: value.title, artists: makeArtists(value.artistCredit), date: value.date, country: value.country, label: value.labelInfo?.first?.label?.name, trackCount: value.media?.reduce(0) { $0 + ($1.trackCount ?? $1.tracks?.count ?? 0) }, score: nil)
    }

    private static func makeCandidate(_ value: ReleaseSearchResult) -> ReleaseCandidate {
        ReleaseCandidate(id: value.id, title: value.title, artists: makeArtists(value.artistCredit), date: value.date, country: value.country, label: value.labelInfo?.first?.label?.name, trackCount: value.trackCount, score: value.score)
    }

    private static func makeArtists(_ credits: [ArtistCredit]?) -> [ProviderArtist] {
        credits?.compactMap { credit in
            guard let artist = credit.artist else { return nil }
            return ProviderArtist(name: artist.name, sortName: artist.sortName, identifier: artist.id)
        } ?? []
    }

    private static func makeMedium(_ value: MediumResponse) -> ProviderMedium {
        ProviderMedium(position: value.position, format: value.format, tracks: value.tracks?.map { track in
            ProviderTrack(position: track.position, title: track.title, artists: makeArtists(track.recording?.artistCredit ?? track.artistCredit), recordingIdentifier: track.recording?.id, lengthMilliseconds: track.length ?? track.recording?.length)
        } ?? [])
    }
}

private struct ReleaseSearchResponse: Decodable {
    let releases: [ReleaseSearchResult]
}

private struct ReleaseSearchResult: Decodable {
    let id: String
    let title: String
    let artistCredit: [ArtistCredit]?
    let date: String?
    let country: String?
    let labelInfo: [LabelInfo]?
    let trackCount: Int?
    let score: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, date, country, score
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
        case trackCount = "track-count"
    }
}

private struct ReleaseResponse: Decodable {
    let id: String
    let title: String
    let artistCredit: [ArtistCredit]?
    let date: String?
    let country: String?
    let labelInfo: [LabelInfo]?
    let barcode: String?
    let media: [MediumResponse]?

    enum CodingKeys: String, CodingKey {
        case id, title, date, country, barcode, media
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
    }
}

private struct ArtistCredit: Decodable {
    let artist: Artist?
}

private struct Artist: Decodable {
    let id: String?
    let name: String
    let sortName: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortName = "sort-name"
    }
}

private struct LabelInfo: Decodable {
    let label: Label?
}

private struct Label: Decodable {
    let name: String
}

private struct MediumResponse: Decodable {
    let position: Int
    let format: String?
    let trackCount: Int?
    let tracks: [TrackResponse]?

    enum CodingKeys: String, CodingKey {
        case position, format, tracks
        case trackCount = "track-count"
    }
}

private struct TrackResponse: Decodable {
    let position: Int
    let title: String
    let length: Int?
    let artistCredit: [ArtistCredit]?
    let recording: Recording?

    enum CodingKeys: String, CodingKey {
        case position, title, length, recording
        case artistCredit = "artist-credit"
    }
}

private struct Recording: Decodable {
    let id: String?
    let length: Int?
    let artistCredit: [ArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, length
        case artistCredit = "artist-credit"
    }
}

private struct ArtworkResponse: Decodable {
    let images: [ArtworkImage]
}

private struct ArtworkImage: Decodable {
    let id: Int
    let image: URL
    let thumbnails: ArtworkThumbnails?
    let types: [String]?
    let front: Bool?
    let back: Bool?
    let width: Int?
    let height: Int?
}

private struct ArtworkThumbnails: Decodable {
    let small: URL?
    let large: URL?
}
