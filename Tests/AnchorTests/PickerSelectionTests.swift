import Foundation
import XCTest

@testable import Anchor

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
