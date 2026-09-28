import Foundation
import XCTest

@testable import TunnelVision

final class ModelTests: XCTestCase {
    func testLockSummaryNamesWhatStaysAllowed() {
        let names = ["com.apple.dt.Xcode": "Xcode", "com.apple.Safari": "Safari"]
        let rules = [
            Rule(bundleID: "com.apple.dt.Xcode"),
            Rule(bundleID: "com.apple.dt.Xcode"),
            Rule(bundleID: "com.apple.Safari", scope: .url, pattern: "github.com"),
            Rule(bundleID: "com.apple.Safari", scope: .window, pattern: ""),
            Rule(bundleID: "com.apple.Mail", effect: .deny),
        ]
        XCTAssertEqual(
            LockSummary.describe(rules: rules, mode: .frozen) { names[$0] ?? $0 },
            "Allowed: Xcode, github.com in Safari. Everything else is frozen.",
            "duplicates, incomplete and deny rules are left out"
        )
        let many = (1...6).map { Rule(bundleID: "app.\($0)") }
        XCTAssertEqual(
            LockSummary.describe(rules: many, mode: .dark) { $0 },
            "Allowed: app.1, app.2, app.3, app.4 and 2 more. Everything else is hidden."
        )
    }

    func testBuiltinPresets() throws {
        let presets = BuiltinPresets.all()
        XCTAssertEqual(presets.map(\.name), ["Coding", "Writing", "Comms", "Reading"])
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count, "built-in ids must be unique")
        for preset in presets {
            XCTAssertTrue(preset.isBuiltIn)
            XCTAssertFalse(preset.rules.isEmpty, "\(preset.name) should ship with rules")
        }
        XCTAssertEqual(presets.first { $0.name == "Coding" }?.mode, .dark)
    }

    func testRuleValidation() {
        XCTAssertTrue(Rule(bundleID: "com.apple.Terminal", scope: .app).isComplete)
        XCTAssertTrue(Rule(bundleID: "com.apple.Safari", scope: .url, pattern: "github.com").isComplete)
        XCTAssertFalse(Rule(bundleID: "com.apple.Safari", scope: .url).isComplete)
        XCTAssertFalse(Rule(bundleID: "", scope: .app).isComplete)
        XCTAssertFalse(Rule(bundleID: "  ", scope: .window, pattern: "  ").isComplete)
    }

    func testCodableRoundTrips() throws {
        let task = TaskItem(
            title: "Write the plan",
            durationSeconds: 1500,
            presetID: UUID(),
            overrides: [Rule(bundleID: "com.apple.mail", scope: .app)]
        )
        let preset = Preset(name: "Comms", isBuiltIn: true, mode: .closed, rules: [Rule(bundleID: "com.apple.mail")])
        let settings = Settings(workSeconds: 3000, breakSeconds: 600, strictMode: true, defaultMode: .frozen, soundOn: false)

        let taskData = try JSONEncoder().encode(task)
        XCTAssertEqual(try JSONDecoder().decode(TaskItem.self, from: taskData), task)

        let presetData = try JSONEncoder().encode(preset)
        XCTAssertEqual(try JSONDecoder().decode(Preset.self, from: presetData), preset)

        let settingsData = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: settingsData), settings)

        let archive = Archive(
            version: 1,
            tasks: [task],
            presets: [preset],
            settings: settings,
            todayCount: 3,
            countDay: "2026-09-02",
            lastUsedPresetID: preset.id
        )
        let archiveData = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(Archive.self, from: archiveData)
        XCTAssertEqual(decoded.tasks, archive.tasks)
        XCTAssertEqual(decoded.presets, archive.presets)
        XCTAssertEqual(decoded.todayCount, 3)
        XCTAssertEqual(decoded.countDay, "2026-09-02")
    }

    func testTimeFormat() {
        XCTAssertEqual(TimeFormat.clock(0), "00:00")
        XCTAssertEqual(TimeFormat.clock(59), "00:59")
        XCTAssertEqual(TimeFormat.clock(60), "01:00")
        XCTAssertEqual(TimeFormat.clock(1500), "25:00")
        XCTAssertEqual(TimeFormat.clock(3661), "1:01:01")
        XCTAssertEqual(TimeFormat.minutes(1500), "25 min")
    }
}
