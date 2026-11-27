import XCTest
@testable import OffloadCore

/// Talks to the real internet. Skipped unless `OFFLOAD_LIVE_WEB=1`, so the suite stays offline.
final class LiveWebTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OFFLOAD_LIVE_WEB"] == "1", "set OFFLOAD_LIVE_WEB=1 to run")
    }

    func testFetchingARealPage() async throws {
        let transport = URLSessionWebTransport(policy: WebPolicy())
        let r = try await transport.get(URL(string: "https://example.com/")!)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(WebTools.render(r, limit: 2_000).contains("Example Domain"))
    }

    func testTheGuardStopsARealRedirectIntoTheLocalNetwork() async throws {
        // httpbin-style redirect services are not reliable; this checks the plain refusal path with a real resolver.
        XCTAssertNotNil(WebGuard.rejection(for: URL(string: "http://localhost:9/")!, policy: WebPolicy()))
        XCTAssertNil(WebGuard.rejection(for: URL(string: "https://example.com/")!, policy: WebPolicy()), "a real public name resolves to public addresses")
    }

    func testARealSearch() async throws {
        let hits = try await DuckDuckGoSearch(transport: URLSessionWebTransport(policy: WebPolicy())).search("swift programming language")
        print("live search hits:", hits.prefix(3))
        XCTAssertFalse(hits.isEmpty, "DuckDuckGo's HTML layout may have changed, or it served a bot check")
        XCTAssertTrue(hits.allSatisfy { URL(string: $0.url)?.host?.hasSuffix("duckduckgo.com") == false })
    }
}
