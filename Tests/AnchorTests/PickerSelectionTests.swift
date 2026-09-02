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
}
