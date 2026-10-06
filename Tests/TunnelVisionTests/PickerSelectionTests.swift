import Foundation
import XCTest

@testable import TunnelVision

final class PickerSelectionTests: XCTestCase {
    private let xcode = "com.apple.dt.Xcode"
    private let slack = "com.tinyspeck.slackmacgap"

    func testWholeAppAndWindowPicksBecomeRules() {
        let rules = SelectionBuilder.rules(
            wholeAppBundles: [xcode],
            windows: [
                PickedWindowRef(bundleID: slack, windowID: 1, title: "Engineering"),
            ]
        )
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.contains { $0.bundleID == xcode && $0.scope == .app })
        XCTAssertTrue(rules.contains { $0.bundleID == slack && $0.scope == .window && $0.pattern == "Engineering" })
    }

    func testWindowOfIncludedAppIsRedundant() {
        let rules = SelectionBuilder.rules(
            wholeAppBundles: [slack],
            windows: [PickedWindowRef(bundleID: slack, windowID: 1, title: "Engineering")]
        )
        XCTAssertEqual(rules.count, 1, "a window pick inside a whole-app pick adds nothing")
        XCTAssertTrue(rules.allSatisfy { $0.scope == .app })
    }

    func testUntitledWindowsCannotBecomeRules() {
        let rules = SelectionBuilder.rules(
            wholeAppBundles: [],
            windows: [PickedWindowRef(bundleID: slack, windowID: 2, title: nil)]
        )
        XCTAssertTrue(rules.isEmpty, "title-less windows cannot be matched later")
    }

    func testSeedFromRulesMarksAppsAndMatchingWindows() {
        let apps = [
            PickerAppInfo(
                id: slack, pid: 10, name: "Slack", bundleID: slack, icon: nil,
                windows: [
                    PickerWindowInfo(id: 11, appPID: 10, title: "Engineering"),
                    PickerWindowInfo(id: 12, appPID: 10, title: "Design"),
                ]
            ),
            PickerAppInfo(
                id: xcode, pid: 20, name: "Xcode", bundleID: xcode, icon: nil,
                windows: [PickerWindowInfo(id: 21, appPID: 20, title: "Anchor")]
            ),
        ]
        let seed = SelectionBuilder.seed(
            apps: apps,
            rules: [
                Rule(bundleID: xcode),
                Rule(bundleID: slack, scope: .window, pattern: "engin"),
            ]
        )
        XCTAssertEqual(seed.wholeAppBundles, [xcode])
        XCTAssertEqual(seed.windowIDs, [11])
    }

    // MARK: Overlay model

    private func fixtureApps() -> [PickerAppInfo] {
        [
            PickerAppInfo(
                id: slack, pid: 10, name: "Slack", bundleID: slack, icon: nil,
                windows: [
                    PickerWindowInfo(id: 11, appPID: 10, title: "Engineering"),
                    PickerWindowInfo(id: 12, appPID: 10, title: nil),
                ]
            ),
            PickerAppInfo(
                id: xcode, pid: 20, name: "Xcode", bundleID: xcode, icon: nil,
                windows: [PickerWindowInfo(id: 21, appPID: 20, title: "Anchor")]
            ),
        ]
    }

    @MainActor
    private func makeModel(whole: Set<String> = [], windows: Set<CGWindowID> = []) -> PickerOverlayModel {
        PickerOverlayModel(
            apps: fixtureApps(),
            wholeAppBundles: whole,
            windowIDs: windows,
            mode: .dark,
            allowsPresetSave: true
        )
    }

    @MainActor
    private func modelWithWindowlessApps(whole: Set<String> = []) -> PickerOverlayModel {
        let windowless = ["com.apple.iCal": "Calendar", "com.todesktop.cursor": "Cursor"].map { bundle, name in
            PickerAppInfo(id: bundle, pid: 30, name: name, bundleID: bundle, icon: nil, windows: [])
        }
        return PickerOverlayModel(
            apps: fixtureApps() + windowless,
            wholeAppBundles: whole,
            windowIDs: [],
            mode: .dark,
            allowsPresetSave: true
        )
    }

    @MainActor
    func testAppsWithoutWindowsAreHiddenByDefault() {
        let model = modelWithWindowlessApps()
        XCTAssertEqual(Set(model.filteredApps.map(\.bundleID)), [slack, xcode])
        XCTAssertEqual(model.hiddenWindowlessCount, 2)

        model.showsWindowlessApps = true
        XCTAssertEqual(model.filteredApps.count, 4, "the toggle lists them again")
        XCTAssertEqual(model.hiddenWindowlessCount, 0)
    }

    @MainActor
    func testAllowedWindowlessAppStaysListed() {
        let model = modelWithWindowlessApps(whole: ["com.apple.iCal"])
        XCTAssertTrue(model.filteredApps.contains { $0.bundleID == "com.apple.iCal" }, "an allowed app must stay visible so it can be dropped")
        XCTAssertFalse(model.filteredApps.contains { $0.bundleID == "com.todesktop.cursor" })
    }

    @MainActor
    func testDroppedWindowlessAppStaysListed() {
        let model = modelWithWindowlessApps(whole: ["com.apple.iCal"])
        let calendar = model.filteredApps.first { $0.bundleID == "com.apple.iCal" }!
        model.toggleApp(calendar)
        XCTAssertTrue(model.filteredApps.contains { $0.bundleID == "com.apple.iCal" }, "a drop must not hide the row, so it can be undone in place")
    }

    @MainActor
    func testSearchFindsWindowlessApps() {
        let model = modelWithWindowlessApps()
        model.search = "calen"
        XCTAssertEqual(model.filteredApps.map(\.bundleID), ["com.apple.iCal"])
    }

    @MainActor
    func testNarrowingToTitlelessWindowIsRefused() {
        let model = makeModel(whole: [slack])
        let slackApp = model.apps.first { $0.bundleID == slack }!
        let titleless = slackApp.windows.first { $0.title == nil }!

        model.toggleWindow(titleless, in: slackApp)
        XCTAssertTrue(model.wholeAppBundles.contains(slack), "title-less narrowing must not un-allow the app")
        XCTAssertTrue(model.windowIDs.isEmpty)
        XCTAssertTrue(model.rules().contains { $0.bundleID == slack && $0.scope == .app })
    }

    @MainActor
    func testNarrowingToTitledWindowReplacesWholeApp() {
        let model = makeModel(whole: [slack])
        let slackApp = model.apps.first { $0.bundleID == slack }!
        let titled = slackApp.windows.first { $0.title == "Engineering" }!

        model.toggleWindow(titled, in: slackApp)
        XCTAssertFalse(model.wholeAppBundles.contains(slack))
        XCTAssertTrue(model.windowIDs.contains(titled.id))
        let rules = model.rules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.scope, .window)
        XCTAssertEqual(rules.first?.pattern, "Engineering")
    }

    @MainActor
    func testSummaryCountsDistinctAppsAndWindowOnlyPicks() {
        let model = makeModel(whole: [xcode], windows: [11])
        let summary = model.summary
        XCTAssertEqual(summary.appCount, 2)
        XCTAssertEqual(summary.windowCount, 1)
    }
}
