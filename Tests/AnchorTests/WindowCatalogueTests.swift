import AppKit
import XCTest

@testable import Anchor

/// The picker lists what Cmd-Tab and Mission Control list: regular apps,
/// with their on-screen windows attached.
final class WindowCatalogueTests: XCTestCase {
    private let selfPID: pid_t = 1
    private let slack = "com.tinyspeck.slackmacgap"
    private let xcode = "com.apple.dt.Xcode"

    private func app(
        _ pid: pid_t,
        _ bundleID: String?,
        _ name: String,
        policy: NSApplication.ActivationPolicy = .regular
    ) -> RunningAppRecord {
        RunningAppRecord(pid: pid, bundleID: bundleID, name: name, activationPolicy: policy, icon: nil)
    }

    private func window(
        _ id: CGWindowID,
        owner: pid_t,
        title: String? = nil,
        layer: Int = 0,
        size: CGSize = CGSize(width: 800, height: 600)
    ) -> WindowRecord {
        WindowRecord(id: id, ownerPID: owner, layer: layer, bounds: CGRect(origin: .zero, size: size), title: title)
    }

    func testOnlyRegularAppsOtherThanSelfAreListed() {
        let apps = [
            app(10, slack, "Slack"),
            app(20, "com.raycast.macos", "Raycast", policy: .accessory),
            app(30, "com.apple.dock", "Dock", policy: .prohibited),
            app(selfPID, "com.anchor.timer", "Anchor"),
            app(40, nil, "Unbundled"),
            app(0, "com.example.ghost", "Ghost"),
        ]
        let windows = [
            window(1, owner: 10, title: "Engineering"),
            window(2, owner: 20, title: "Raycast"),
            window(3, owner: 30),
            window(4, owner: selfPID, title: "Anchor"),
            window(5, owner: 40, title: "Unbundled"),
        ]
        let listed = WindowCatalogue.assemble(apps: apps, windows: windows, selfPID: selfPID)
        XCTAssertEqual(listed.map(\.bundleID), [slack], "accessory, prohibited, self and unbundled apps are not Cmd-Tab apps")
        XCTAssertEqual(listed.first?.windows.map(\.id), [1])
    }

    func testRegularAppWithoutOnScreenWindowsIsStillListed() {
        let listed = WindowCatalogue.assemble(
            apps: [app(20, xcode, "Xcode")],
            windows: [],
            selfPID: selfPID
        )
        XCTAssertEqual(listed.map(\.bundleID), [xcode], "hidden apps and apps on other Spaces remain allowable")
        XCTAssertEqual(listed.first?.windows, [])
    }

    func testWindowsAreFilteredTrimmedAndSorted() {
        let windows = [
            window(1, owner: 10, title: "  Zebra channel "),
            window(2, owner: 10, title: nil),
            window(3, owner: 10, title: "   "),
            window(4, owner: 10, title: "Alpha channel"),
            window(5, owner: 10, title: "Menu", layer: 25),
            window(6, owner: 10, title: "Tooltip", size: CGSize(width: 60, height: 40)),
            window(7, owner: 99, title: "Orphan"),
        ]
        let listed = WindowCatalogue.assemble(apps: [app(10, slack, "Slack")], windows: windows, selfPID: selfPID)
        let slackWindows = listed.first?.windows ?? []
        XCTAssertEqual(slackWindows.map(\.id), [4, 1, 2, 3], "titled first, alphabetical; non-layer-0 and tiny windows dropped")
        XCTAssertEqual(slackWindows.map(\.title), ["Alpha channel", "Zebra channel", nil, nil], "titles trimmed, blank titles become nil")
    }

    func testWindowWithoutReportedBoundsIsKept() {
        let record = WindowRecord(id: 1, ownerPID: 10, layer: 0, bounds: nil, title: "Untracked")
        let listed = WindowCatalogue.assemble(apps: [app(10, slack, "Slack")], windows: [record], selfPID: selfPID)
        XCTAssertEqual(listed.first?.windows.map(\.id), [1])
    }

    func testTwoInstancesOfOneAppShareAnEntry() {
        let apps = [app(10, slack, "Slack"), app(11, slack, "Slack")]
        let windows = [window(1, owner: 10, title: "One"), window(2, owner: 11, title: "Two")]
        let listed = WindowCatalogue.assemble(apps: apps, windows: windows, selfPID: selfPID)
        XCTAssertEqual(listed.count, 1, "rules are per bundle, so the picker shows one entry")
        XCTAssertEqual(listed.first?.windows.map(\.id), [1, 2])
    }

    func testAppsSortByNameCaseInsensitively() {
        let apps = [app(10, "com.example.b", "beta"), app(20, "com.example.a", "Alpha"), app(30, "com.example.c", "Charlie")]
        let listed = WindowCatalogue.assemble(apps: apps, windows: [], selfPID: selfPID)
        XCTAssertEqual(listed.map(\.name), ["Alpha", "beta", "Charlie"])
    }
}
