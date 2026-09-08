import Foundation
import XCTest

@testable import TunnelVision

final class BrowserURLTests: XCTestCase {
    private let helium = "net.imput.helium"

    func testURLPatternKeepsHostAndPathOnly() {
        XCTAssertEqual(PickerWindowInfo.pattern(fromURL: "https://github.com/org/repo/pull/1?x=1#files"), "github.com/org/repo/pull/1")
        XCTAssertEqual(PickerWindowInfo.pattern(fromURL: "https://mail.google.com/"), "mail.google.com")
        XCTAssertEqual(PickerWindowInfo.pattern(fromURL: " https://docs.rs/tokio/latest/ "), "docs.rs/tokio/latest")
        XCTAssertNil(PickerWindowInfo.pattern(fromURL: "chrome://newtab"), "no host, no name")
        XCTAssertNil(PickerWindowInfo.pattern(fromURL: ""))
    }

    func testDisplayNamePrefersTitleThenURL() {
        let titled = PickerWindowInfo(id: 1, appPID: 9, title: "Pull request", url: "https://github.com/org/repo/pull/1")
        XCTAssertEqual(titled.displayName, "Pull request")
        let urlOnly = PickerWindowInfo(id: 2, appPID: 9, title: nil, url: "https://github.com/org/repo")
        XCTAssertEqual(urlOnly.displayName, "github.com/org/repo")
        XCTAssertNil(PickerWindowInfo(id: 3, appPID: 9, title: nil).displayName)
    }

    func testParsesScriptOutput() {
        let output = """
        0\t25\t1440\t900\tPull request · GitHub - Helium\thttps://github.com/org/repo/pull/1
        1440\t25\t2880\t900\t\thttps://docs.rs/tokio
        broken line
        10\t10\t20\t20\tNo URL\t
        """
        let records = BrowserWindowURLs.parse(output)
        XCTAssertEqual(records.count, 2, "malformed lines and windows without a URL are skipped")
        XCTAssertEqual(records[0].bounds, CGRect(x: 0, y: 25, width: 1440, height: 875))
        XCTAssertEqual(records[0].name, "Pull request · GitHub - Helium")
        XCTAssertEqual(records[1].url, "https://docs.rs/tokio")
        XCTAssertEqual(records[1].name, "")
    }

    func testMatchesByTitleThenByGeometry() {
        let windows = [
            PickerWindowInfo(id: 1, appPID: 9, title: "Docs - Helium", bounds: CGRect(x: 0, y: 25, width: 1440, height: 875)),
            PickerWindowInfo(id: 2, appPID: 9, title: nil, bounds: CGRect(x: 1440, y: 25, width: 1440, height: 875)),
            PickerWindowInfo(id: 3, appPID: 9, title: nil, bounds: CGRect(x: 100, y: 100, width: 500, height: 400)),
        ]
        let records = [
            BrowserWindowURLs.ScriptedWindow(bounds: CGRect(x: 1443, y: 25, width: 1437, height: 875), name: "", url: "https://b.example"),
            BrowserWindowURLs.ScriptedWindow(bounds: CGRect(x: 0, y: 25, width: 1440, height: 875), name: "Docs - Helium", url: "https://a.example"),
        ]
        let matched = BrowserWindowURLs.match(windows: windows, records: records)
        XCTAssertEqual(matched[1], "https://a.example", "title match wins")
        XCTAssertEqual(matched[2], "https://b.example", "geometry within tolerance")
        XCTAssertNil(matched[3], "nothing left to match")
    }

    func testScriptTargetsTheBundleAndUsesEachDictionary() {
        let chromium = BrowserWindowURLs.script(forBundle: helium)
        XCTAssertTrue(chromium.contains("tell application id \"net.imput.helium\""))
        XCTAssertTrue(chromium.contains("URL of active tab of w"))
        XCTAssertTrue(chromium.contains("with timeout"), "a stalled browser must not hang the picker")
        let safari = BrowserWindowURLs.script(forBundle: "com.apple.Safari")
        XCTAssertTrue(safari.contains("URL of current tab of w"))
        XCTAssertFalse(BrowserWindowURLs.supports("org.mozilla.firefox"), "Firefox exposes no tabs to scripting")
    }

    // MARK: Picks and seeding

    func testBrowserWindowPicksBecomeURLRules() {
        let rules = SelectionBuilder.rules(
            wholeAppBundles: [],
            windows: [
                PickedWindowRef(bundleID: helium, windowID: 1, title: nil, url: "https://github.com/org/repo/pull/1?tab=files"),
                PickedWindowRef(bundleID: helium, windowID: 2, title: "Docs", url: "https://docs.rs/tokio"),
                PickedWindowRef(bundleID: helium, windowID: 3, title: nil, url: nil),
                PickedWindowRef(bundleID: helium, windowID: 4, title: "Reddit", url: "https://www.reddit.com/r/swift", siteWide: true),
                PickedWindowRef(bundleID: "com.apple.dt.Xcode", windowID: 5, title: "Anchor", url: nil),
            ]
        )
        XCTAssertEqual(rules.count, 4, "a window with neither title nor URL cannot become a rule")
        XCTAssertEqual(rules[0].scope, .url)
        XCTAssertEqual(rules[0].pattern, "github.com/org/repo/pull/1")
        XCTAssertEqual(rules[1].scope, .url, "the URL wins over the title: a tab switch would change the title")
        XCTAssertEqual(rules[1].pattern, "docs.rs/tokio")
        XCTAssertEqual(rules[2].scope, .url)
        XCTAssertEqual(rules[2].pattern, "reddit.com", "site-wide keeps the host only")
        XCTAssertEqual(rules[3].scope, .window, "without a URL the title is the handle")
        XCTAssertEqual(LockPolicy.allowedBundleIDs(rules: rules), [helium, "com.apple.dt.Xcode"])
    }

    func testSeedMarksSiteWideRules() {
        let browser = PickerAppInfo(
            id: helium, pid: 9, name: "Helium", bundleID: helium, icon: nil,
            windows: [
                PickerWindowInfo(id: 1, appPID: 9, title: nil, url: "https://github.com/org/repo/pull/1"),
                PickerWindowInfo(id: 2, appPID: 9, title: nil, url: "https://docs.rs/tokio"),
            ]
        )
        let seed = SelectionBuilder.seed(apps: [browser], rules: [
            Rule(bundleID: helium, scope: .url, pattern: "github.com/org/repo"),
            Rule(bundleID: helium, scope: .url, pattern: "docs.rs"),
        ])
        XCTAssertEqual(seed.windowIDs, [1, 2])
        XCTAssertEqual(seed.siteWideWindowIDs, [2], "a host-only pattern is a site-wide pick")
    }

    @MainActor
    func testSiteWideToggleWidensTheRule() {
        let window = PickerWindowInfo(id: 1, appPID: 9, title: nil, url: "https://github.com/org/repo/pull/1")
        let browser = PickerAppInfo(id: helium, pid: 9, name: "Helium", bundleID: helium, icon: nil, windows: [window])
        let model = PickerOverlayModel(apps: [browser], wholeAppBundles: [], windowIDs: [1], mode: .dark, allowsPresetSave: true)
        XCTAssertEqual(model.urlPattern(for: window), "github.com/org/repo/pull/1")
        model.setSiteWide(true, for: window)
        XCTAssertEqual(model.urlPattern(for: window), "github.com")
        XCTAssertEqual(model.rules().first?.pattern, "github.com")
        model.toggleWindow(window, in: browser)
        XCTAssertFalse(model.isSiteWide(window), "dropping the window drops its scope too")
    }

    func testSeedMarksWindowsMatchingAURLRuleOrFallsBackToTheApp() {
        let browser = PickerAppInfo(
            id: helium, pid: 9, name: "Helium", bundleID: helium, icon: nil,
            windows: [
                PickerWindowInfo(id: 1, appPID: 9, title: nil, url: "https://github.com/org/repo/pull/1"),
                PickerWindowInfo(id: 2, appPID: 9, title: nil, url: "https://news.example"),
            ]
        )
        let matched = SelectionBuilder.seed(apps: [browser], rules: [Rule(bundleID: helium, scope: .url, pattern: "github.com/org/repo")])
        XCTAssertEqual(matched.windowIDs, [1])
        XCTAssertTrue(matched.wholeAppBundles.isEmpty)

        let unmatched = SelectionBuilder.seed(apps: [browser], rules: [Rule(bundleID: helium, scope: .url, pattern: "gitlab.com")])
        XCTAssertTrue(unmatched.windowIDs.isEmpty)
        XCTAssertEqual(unmatched.wholeAppBundles, [helium], "the URL rule still admits the app")
    }

    @MainActor
    func testLateURLsNameWindowsAndNarrowSeededURLRules() {
        let browser = PickerAppInfo(
            id: helium, pid: 9, name: "Helium", bundleID: helium, icon: nil,
            windows: [
                PickerWindowInfo(id: 1, appPID: 9, title: nil),
                PickerWindowInfo(id: 2, appPID: 9, title: nil),
            ]
        )
        let rules = [Rule(bundleID: helium, scope: .url, pattern: "github.com/org/repo")]
        let seed = SelectionBuilder.seed(apps: [browser], rules: rules)
        let model = PickerOverlayModel(
            apps: [browser], wholeAppBundles: seed.wholeAppBundles, windowIDs: seed.windowIDs, mode: .dark, allowsPresetSave: true
        )
        XCTAssertTrue(model.isWhole(browser), "before the browser answers, the URL rule reads as whole-app")
        XCTAssertNil(model.apps[0].windows[0].displayName)

        model.applyWindowURLs([1: "https://github.com/org/repo/pull/7", 2: "https://news.example"], seededFrom: rules)
        XCTAssertEqual(model.apps[0].windows[0].displayName, "github.com/org/repo/pull/7")
        XCTAssertFalse(model.isWhole(browser), "narrowed to the matching window")
        XCTAssertEqual(model.windowIDs, [1])
        let rebuilt = model.rules()
        XCTAssertEqual(rebuilt.map(\.scope), [.url])
        XCTAssertEqual(rebuilt.first?.pattern, "github.com/org/repo/pull/7")
    }

    @MainActor
    func testWholeAppStaysWholeWhenAnAppRuleSaysSo() {
        let browser = PickerAppInfo(
            id: helium, pid: 9, name: "Helium", bundleID: helium, icon: nil,
            windows: [PickerWindowInfo(id: 1, appPID: 9, title: nil)]
        )
        let rules = [Rule(bundleID: helium), Rule(bundleID: helium, scope: .url, pattern: "github.com")]
        let seed = SelectionBuilder.seed(apps: [browser], rules: rules)
        let model = PickerOverlayModel(
            apps: [browser], wholeAppBundles: seed.wholeAppBundles, windowIDs: seed.windowIDs, mode: .dark, allowsPresetSave: true
        )
        model.applyWindowURLs([1: "https://github.com/x"], seededFrom: rules)
        XCTAssertTrue(model.isWhole(browser), "an explicit app rule is not undone by a URL match")
    }

    @MainActor
    func testTogglingAWindowNamedOnlyByURLNarrowsTheApp() {
        let window = PickerWindowInfo(id: 1, appPID: 9, title: nil, url: "https://github.com/org/repo")
        let browser = PickerAppInfo(id: helium, pid: 9, name: "Helium", bundleID: helium, icon: nil, windows: [window])
        let model = PickerOverlayModel(apps: [browser], wholeAppBundles: [helium], windowIDs: [], mode: .dark, allowsPresetSave: true)
        model.toggleWindow(window, in: browser)
        XCTAssertFalse(model.isWhole(browser))
        XCTAssertEqual(model.windowIDs, [1])
        XCTAssertEqual(model.rules().first?.scope, .url)
    }
}
