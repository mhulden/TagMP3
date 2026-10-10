import Foundation
import XCTest
import TagMP3Providers

final class MusicBrainzProviderTests: XCTestCase {
    func testSearchDecodesCandidatesAndSendsUserAgent() async throws {
        let fixture = Data("""
        {"releases":[{"id":"11111111-1111-4111-8111-111111111111","title":"Album","artist-credit":[{"artist":{"id":"22222222-2222-4222-8222-222222222222","name":"Artist","sort-name":"Artist, A"}}],"date":"1990","country":"US","track-count":10,"score":98}]}
        """.utf8)
        let http = RecordingHTTPClient(responses: [fixture])
        let provider = MusicBrainzProvider(application: makeApplication(), httpClient: http, limiter: RequestRateLimiter(requestsPerSecond: 1_000), baseURL: URL(string: "https://example.test/ws/2")!)

        let results = try await provider.searchReleases(ReleaseSearchQuery(title: "Album", artist: "Artist"))
        XCTAssertEqual(results.first?.title, "Album")
        XCTAssertEqual(results.first?.artists.first?.name, "Artist")
        let request = await http.requests.first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "tagmp3/test (https://example.test/tagmp3)")
        XCTAssertTrue(request?.url?.query?.contains("recording") == true)
    }

    func testSearchFallsBackToAlbumAndArtistWhenRecordingConstraintMisses() async throws {
        let noMatch = Data("{\"releases\":[]}".utf8)
        let fallback = Data("""
        {"releases":[{"id":"11111111-1111-4111-8111-111111111111","title":"Remain in Light","artist-credit":[{"artist":{"name":"Talking Heads"}}]}]}
        """.utf8)
        let http = RecordingHTTPClient(responses: [noMatch, fallback])
        let provider = MusicBrainzProvider(application: makeApplication(), httpClient: http, limiter: RequestRateLimiter(requestsPerSecond: 1_000), baseURL: URL(string: "https://example.test/ws/2")!)

        let results = try await provider.searchReleases(ReleaseSearchQuery(title: "Once in a Lifetime", artist: "Talking Heads", album: "Remain in Light"))

        XCTAssertEqual(results.first?.title, "Remain in Light")
        let requestCount = await http.requests.count
        XCTAssertEqual(requestCount, 2)
        let requests = await http.requests
        XCTAssertTrue(requests.first?.url?.query?.contains("recording") == true)
        XCTAssertFalse(requests.last?.url?.query?.contains("recording") == true)
    }

    func testReleaseDetailsDecodesMediaAndTracks() async throws {
        let fixture = Data("""
        {"id":"11111111-1111-4111-8111-111111111111","title":"Album","artist-credit":[{"artist":{"name":"Artist"}}],"barcode":"123","media":[{"position":1,"format":"CD","track-count":1,"tracks":[{"position":1,"title":"Song","length":1234,"recording":{"id":"33333333-3333-4333-8333-333333333333","artist-credit":[{"artist":{"name":"Artist"}}]}}]}]}
        """.utf8)
        let provider = MusicBrainzProvider(application: makeApplication(), httpClient: RecordingHTTPClient(responses: [fixture]), limiter: RequestRateLimiter(requestsPerSecond: 1_000), baseURL: URL(string: "https://example.test/ws/2")!)
        let details = try await provider.releaseDetails(for: "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(details.barcode, "123")
        XCTAssertEqual(details.media.first?.tracks.first?.title, "Song")
        XCTAssertEqual(details.media.first?.tracks.first?.recordingIdentifier, "33333333-3333-4333-8333-333333333333")
    }

    func testArtworkDecodesFrontAndThumbnail() async throws {
        let fixture = Data("""
        {"images":[{"id":1,"image":"https://cover.example/front.jpg","thumbnails":{"small":"https://cover.example/front-250.jpg","large":"https://cover.example/front-500.jpg"},"types":["Front"],"front":true,"back":false,"width":500,"height":500}]}
        """.utf8)
        let provider = MusicBrainzProvider(application: makeApplication(), httpClient: RecordingHTTPClient(responses: [fixture]), limiter: RequestRateLimiter(requestsPerSecond: 1_000))
        let artwork = try await provider.artwork(for: "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(artwork.first?.front, true)
        XCTAssertEqual(artwork.first?.thumbnailURL?.absoluteString, "https://cover.example/front-500.jpg")
    }

    private func makeApplication() -> ProviderApplication {
        ProviderApplication(name: "tagmp3", version: "test", contactURL: URL(string: "https://example.test/tagmp3")!)
    }
}

private actor RecordingHTTPClient: ProviderHTTPClient {
    private var responses: [Data]
    private(set) var requests: [URLRequest] = []

    init(responses: [Data]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        return (responses.removeFirst(), 200)
    }
}
