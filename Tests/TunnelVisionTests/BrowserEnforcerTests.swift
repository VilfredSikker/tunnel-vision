import Foundation
import XCTest

@testable import TunnelVision

/// Stands in for the browser's scripting interface.
@MainActor
final class FakeBrowserScripting: BrowserScripting {
    var running: Set<String> = []
    var states: [String: [BrowserWindowState]] = [:]
    var answers = true
    var activated: [(bundle: String, window: Int, index: Int)] = []
    var navigated: [(bundle: String, window: Int, tab: Int, url: String)] = []

    func isRunning(_ bundleID: String) -> Bool { running.contains(bundleID) }
    func displayName(of bundleID: String) -> String { "Helium" }

    func windows(of bundleID: String) async -> [BrowserWindowState]? {
        answers ? (states[bundleID] ?? []) : nil
    }

    func activateTab(bundleID: String, windowID: Int, index: Int) async -> Bool {
        activated.append((bundleID, windowID, index))
        return true
    }

    func navigate(bundleID: String, windowID: Int, tabIndex: Int, url: String) async -> Bool {
        navigated.append((bundleID, windowID, tabIndex, url))
        return true
    }
}

private let helium = "net.imput.helium"
private let chrome = "com.google.Chrome"

@MainActor
final class BrowserEnforcerTests: XCTestCase {
    private let github = BrowserRuleSet(urlPatterns: ["github.com/org/repo"], titlePatterns: [])

    private func window(_ id: Int, name: String = "", active: Int = 1, minimized: Bool = false, urls: [String]) -> BrowserWindowState {
        BrowserWindowState(
            id: id,
            name: name,
            isMinimized: minimized,
            activeTabIndex: active,
            tabs: urls.enumerated().map { BrowserTab(index: $0.offset + 1, url: $0.element) }
        )
    }

    // MARK: Policy

    func testRuleSetsCoverManagedBrowsersWithSiteRulesOnly() {
        let rules = [
            Rule(bundleID: helium, scope: .url, pattern: " GitHub.com/org "),
            Rule(bundleID: helium, scope: .window, pattern: "Docs"),
            Rule(bundleID: chrome, scope: .url, pattern: "example.com"),
            Rule(bundleID: chrome),
            Rule(bundleID: "com.apple.Safari", scope: .url, pattern: "apple.com"),
            Rule(bundleID: "org.mozilla.firefox", scope: .url, pattern: "mozilla.org"),
            Rule(bundleID: "com.apple.dt.Xcode", scope: .window, pattern: "Anchor"),
        ]
        let sets = BrowserLockPolicy.ruleSets(rules: rules, managed: Browsers.managed(unmanaged: ["com.apple.Safari"]))
        XCTAssertEqual(Set(sets.keys), [helium], "Chrome is allowed whole, Safari is unmanaged, Firefox is unsupported, Xcode has no site rules")
        XCTAssertEqual(sets[helium], BrowserRuleSet(urlPatterns: ["github.com/org"], titlePatterns: ["docs"]))
    }

    func testCompliance() {
        XCTAssertTrue(BrowserLockPolicy.isCompliant(window(1, urls: ["https://github.com/org/repo/pull/1"]), ruleSet: github))
        XCTAssertTrue(BrowserLockPolicy.isCompliant(window(1, urls: ["chrome://newtab"]), ruleSet: github), "not a page")
        XCTAssertTrue(BrowserLockPolicy.isCompliant(window(1, urls: [""]), ruleSet: github))
        XCTAssertTrue(BrowserLockPolicy.isCompliant(window(1, urls: ["https://github.com/org/repo/pull/1", "https://reddit.com"]), ruleSet: github), "only the active tab counts")
        XCTAssertFalse(BrowserLockPolicy.isCompliant(window(1, active: 2, urls: ["https://github.com/org/repo", "https://reddit.com"]), ruleSet: github))
        let titled = BrowserRuleSet(urlPatterns: ["github.com"], titlePatterns: ["docs"])
        XCTAssertTrue(BrowserLockPolicy.isCompliant(window(1, name: "Rust Docs", urls: ["https://docs.rs"]), ruleSet: titled), "a window rule keeps the window whatever it shows")
    }

    func testPlanPrefersAnotherAllowedTabThenLastAllowedPageThenTheRule() {
        let mixed = window(1, active: 2, urls: ["https://github.com/org/repo/issues", "https://reddit.com/r/x"])
        XCTAssertEqual(BrowserLockPolicy.plan(window: mixed, ruleSet: github, lastAllowedURL: nil), .activateTab(index: 1))

        let lone = window(2, urls: ["https://reddit.com/r/x"])
        XCTAssertEqual(
            BrowserLockPolicy.plan(window: lone, ruleSet: github, lastAllowedURL: "https://github.com/org/repo/pull/9"),
            .navigate(tabIndex: 1, url: "https://github.com/org/repo/pull/9")
        )
        XCTAssertEqual(
            BrowserLockPolicy.plan(window: lone, ruleSet: github, lastAllowedURL: nil),
            .navigate(tabIndex: 1, url: "https://github.com/org/repo")
        )
        XCTAssertNil(BrowserLockPolicy.plan(window: window(3, minimized: true, urls: ["https://reddit.com"]), ruleSet: github, lastAllowedURL: nil), "minimised windows are left alone")
        XCTAssertNil(BrowserLockPolicy.plan(window: window(4, urls: ["https://github.com/org/repo"]), ruleSet: github, lastAllowedURL: nil))
    }

    // MARK: Scripts

    func testStateScriptOutputParsesIntoWindows() {
        let output = """
        7\t1\t2\tfalse\tPull request · GitHub\thttps://github.com/org/repo/pull/1
        7\t2\t2\tfalse\tPull request · GitHub\thttps://reddit.com/r/x
        9\t1\t1\ttrue\tNew Tab\t
        broken
        """
        let windows = BrowserScripts.parseState(output)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].id, 7)
        XCTAssertEqual(windows[0].activeTabIndex, 2)
        XCTAssertEqual(windows[0].name, "Pull request · GitHub")
        XCTAssertEqual(windows[0].tabs.map(\.url), ["https://github.com/org/repo/pull/1", "https://reddit.com/r/x"])
        XCTAssertEqual(windows[0].activeTab?.url, "https://reddit.com/r/x")
        XCTAssertTrue(windows[1].isMinimized)
        XCTAssertEqual(windows[1].tabs, [BrowserTab(index: 1, url: "")])
    }

    func testScriptsUseEachBrowsersDictionary() {
        let chromium = BrowserScripts.state(forBundle: helium)
        XCTAssertTrue(chromium.contains("tell application id \"net.imput.helium\""))
        XCTAssertTrue(chromium.contains("active tab index of w"))
        XCTAssertTrue(chromium.contains("minimized of w"))
        XCTAssertTrue(chromium.contains("with timeout"), "a stalled browser must not hang the loop")
        let safari = BrowserScripts.state(forBundle: "com.apple.Safari")
        XCTAssertTrue(safari.contains("index of current tab of w"))
        XCTAssertTrue(safari.contains("miniaturized of w"))

        XCTAssertTrue(BrowserScripts.activateTab(bundleID: helium, windowID: 7, index: 2).contains("set active tab index of window id 7 to 2"))
        XCTAssertTrue(BrowserScripts.activateTab(bundleID: "com.apple.Safari", windowID: 7, index: 2).contains("tell window id 7 to set current tab to tab 2"))
        let navigate = BrowserScripts.navigate(bundleID: helium, windowID: 7, tabIndex: 1, url: "https://a.example/\"q\"")
        XCTAssertTrue(navigate.contains("set URL of tab 1 of window id 7 to \"https://a.example/\\\"q\\\"\""), "quotes in the URL are escaped")
    }

    // MARK: Enforcer

    private func makeEnforcer(_ fake: FakeBrowserScripting, unmanaged: Set<String> = []) -> BrowserEnforcer {
        BrowserEnforcer(scripting: fake, unmanagedBrowsers: { unmanaged }, autoPoll: false)
    }

    func testSweepSteersWindowsAndRemembersAllowedPages() async {
        let fake = FakeBrowserScripting()
        fake.running = [helium]
        fake.states[helium] = [
            window(1, urls: ["https://github.com/org/repo/pull/4"]),
            window(2, active: 2, urls: ["https://github.com/org/repo", "https://news.example"]),
        ]
        let enforcer = makeEnforcer(fake)
        var notices: [String] = []
        enforcer.onBlockedSite = { _, _, host in notices.append(host) }
        enforcer.lock(rules: [Rule(bundleID: helium, scope: .url, pattern: "github.com/org/repo")])
        XCTAssertTrue(enforcer.isActive)

        await enforcer.sweep()
        XCTAssertEqual(fake.activated.map(\.window), [2], "the window with another allowed tab switches to it")
        XCTAssertEqual(fake.activated.first?.index, 1)
        XCTAssertTrue(fake.navigated.isEmpty)
        XCTAssertEqual(notices, ["news.example"])

        // Window 1 wanders off in its only tab: back to the page it showed.
        fake.states[helium] = [window(1, urls: ["https://www.reddit.com/r/x"])]
        await enforcer.sweep()
        XCTAssertEqual(fake.navigated.map(\.url), ["https://github.com/org/repo/pull/4"])
        XCTAssertEqual(notices, ["news.example", "reddit.com"])
    }

    func testNotRunningOrNotAnsweringBrowsersAreSkipped() async {
        let fake = FakeBrowserScripting()
        fake.states[helium] = [window(1, urls: ["https://reddit.com"])]
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: helium, scope: .url, pattern: "github.com")])

        await enforcer.sweep()
        XCTAssertTrue(fake.navigated.isEmpty, "a browser that is not running is never scripted (that would launch it)")

        fake.running = [helium]
        fake.answers = false
        await enforcer.sweep()
        XCTAssertTrue(fake.navigated.isEmpty, "Automation declined: nothing to do")
    }

    func testAllowForSessionWidensThePatterns() async {
        let fake = FakeBrowserScripting()
        fake.running = [helium]
        fake.states[helium] = [window(1, urls: ["https://news.example/today"])]
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: helium, scope: .url, pattern: "github.com")])

        enforcer.allowForSession(bundleID: helium, site: "news.example")
        XCTAssertEqual(enforcer.effectiveRuleSet(for: helium)?.urlPatterns, ["github.com", "news.example"])
        await enforcer.sweep()
        XCTAssertTrue(fake.navigated.isEmpty)
    }

    func testUnmanagedBrowserAndWholeAppRulesLeaveTheLayerInactive() {
        let fake = FakeBrowserScripting()
        let unmanaged = makeEnforcer(fake, unmanaged: [helium])
        unmanaged.lock(rules: [Rule(bundleID: helium, scope: .url, pattern: "github.com")])
        XCTAssertFalse(unmanaged.isActive)

        let whole = makeEnforcer(fake)
        whole.lock(rules: [Rule(bundleID: helium), Rule(bundleID: helium, scope: .url, pattern: "github.com")])
        XCTAssertFalse(whole.isActive)
    }

    func testUnlockClearsSessionState() async {
        let fake = FakeBrowserScripting()
        fake.running = [helium]
        let enforcer = makeEnforcer(fake)
        enforcer.lock(rules: [Rule(bundleID: helium, scope: .url, pattern: "github.com")])
        enforcer.allowForSession(bundleID: helium, site: "news.example")
        enforcer.unlock()
        XCTAssertFalse(enforcer.isActive)
        XCTAssertNil(enforcer.effectiveRuleSet(for: helium))

        enforcer.lock(rules: [Rule(bundleID: helium, scope: .url, pattern: "github.com")])
        XCTAssertEqual(enforcer.effectiveRuleSet(for: helium)?.urlPatterns, ["github.com"], "session additions do not survive the session")
    }
}
