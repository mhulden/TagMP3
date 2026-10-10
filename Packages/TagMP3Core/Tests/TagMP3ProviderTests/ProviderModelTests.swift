import XCTest
import TagMP3Providers

final class ProviderModelTests: XCTestCase {
    func testUserAgentIsContactableAndStable() {
        let app = ProviderApplication(name: "tagmp3", version: "0.1", contactURL: URL(string: "https://example.com/tagmp3")!)
        XCTAssertEqual(app.userAgent, "tagmp3/0.1 (https://example.com/tagmp3)")
    }

    func testSearchLimitIsClamped() {
        XCTAssertEqual(ReleaseSearchQuery(limit: 0).limit, 1)
        XCTAssertEqual(ReleaseSearchQuery(limit: 500).limit, 100)
    }

    func testCacheHonorsExpiration() async {
        let data = Data("fixture".utf8)
        let validCache = InMemoryProviderResponseCache(now: { Date(timeIntervalSince1970: 100) })
        await validCache.insert(data, for: "release:1", expiresAt: Date(timeIntervalSince1970: 110))
        let validResponse = await validCache.response(for: "release:1")
        XCTAssertEqual(validResponse, data)

        let expiredCache = InMemoryProviderResponseCache(now: { Date(timeIntervalSince1970: 111) })
        await expiredCache.insert(data, for: "release:1", expiresAt: Date(timeIntervalSince1970: 110))
        let expiredResponse = await expiredCache.response(for: "release:1")
        XCTAssertNil(expiredResponse)
    }
}
