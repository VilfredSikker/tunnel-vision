import XCTest

@testable import TunnelVision

final class URLPatternTests: XCTestCase {
    func testParsePatternDropsSchemeAndTrailingSlash() {
        XCTAssertEqual(URLPattern.parse("GitHub.com/Org/Repo/"), URLPattern.Parts(host: "github.com", path: "/org/repo"))
        XCTAssertEqual(URLPattern.parse("https://docs.rs"), URLPattern.Parts(host: "docs.rs", path: ""))
        XCTAssertNil(URLPattern.parse("   "))
        XCTAssertNil(URLPattern.parse("/just/a/path"))
    }

    func testHostMatchesItselfAndSubdomainsOnly() {
        XCTAssertTrue(URLPattern.matches("github.com", url: "https://github.com/x"))
        XCTAssertTrue(URLPattern.matches("github.com", url: "https://gist.github.com/x"))
        XCTAssertFalse(URLPattern.matches("github.com", url: "https://notgithub.com/x"))
        XCTAssertFalse(URLPattern.matches("www.example.com", url: "https://example.com/"))
    }

    func testPathMatchesAtSegmentBoundaries() {
        XCTAssertTrue(URLPattern.matches("github.com/org/repo", url: "https://github.com/org/repo"))
        XCTAssertTrue(URLPattern.matches("github.com/org/repo", url: "https://github.com/org/repo/pull/1?x=1#y"))
        XCTAssertFalse(URLPattern.matches("github.com/org/repo", url: "https://github.com/org/repository"))
        XCTAssertFalse(URLPattern.matches("github.com/org/repo", url: "https://github.com/org"))
    }

    func testOnlyWebPagesMatchOrCount() {
        XCTAssertFalse(URLPattern.matches("newtab", url: "chrome://newtab"))
        XCTAssertFalse(URLPattern.isWeb("chrome://settings"))
        XCTAssertFalse(URLPattern.isWeb("about:blank"))
        XCTAssertFalse(URLPattern.isWeb(""))
        XCTAssertTrue(URLPattern.isWeb("HTTPS://Example.com"))
        XCTAssertTrue(URLPattern.matchesAny(["a.example", "b.example"], url: "http://b.example/page"))
        XCTAssertFalse(URLPattern.matchesAny([], url: "http://b.example/page"))
    }

    func testSiteDropsWWWAndURLForPatternAddsHTTPS() {
        XCTAssertEqual(URLPattern.site(fromURL: "https://www.reddit.com/r/x"), "reddit.com")
        XCTAssertEqual(URLPattern.site(fromURL: "https://mail.google.com/mail"), "mail.google.com")
        XCTAssertNil(URLPattern.site(fromURL: "chrome://newtab"))
        XCTAssertEqual(URLPattern.url(forPattern: "github.com/org/repo/"), "https://github.com/org/repo")
        XCTAssertNil(URLPattern.url(forPattern: ""))
    }
}
