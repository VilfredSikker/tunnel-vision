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

    func testTaskRowHoverShowsFullTitleDoneWhenAndGoal() {
        let goal = Goal(title: "Ship the data platform")
        let task = TaskItem(title: "Write the OpenTofu for data warehouse", durationSeconds: 3000,
                            doneWhen: "Plan applies cleanly", goalID: goal.id)
        XCTAssertEqual(
            TaskRowView.hoverHelp(for: task, goal: goal),
            "Write the OpenTofu for data warehouse\nDone when: Plan applies cleanly\nGoal: Ship the data platform"
        )
        let bare = TaskItem(title: "", durationSeconds: 1500)
        XCTAssertEqual(TaskRowView.hoverHelp(for: bare, goal: nil), "Untitled task")
    }

    func testTaskRowHoverListsDescriptionAndChecklist() {
        let task = TaskItem(title: "Weekly review", durationSeconds: 1500, notes: "Inbox to zero first",
                            checklist: [ChecklistItem(text: "Inbox", done: true), ChecklistItem(text: "Review https://github.com/a/b/pull/7")])
        XCTAssertEqual(
            TaskRowView.hoverHelp(for: task, goal: nil),
            "Weekly review\nInbox to zero first\n☑ Inbox\n☐ Review a/b#7"
        )
    }

    func testLinksGetShortReadableLabels() throws {
        func label(_ text: String) throws -> String {
            LinkText.shortLabel(for: try XCTUnwrap(URL(string: text)))
        }
        XCTAssertEqual(try label("https://github.com/VilfredSikker/tunnel-vision/pull/3/files"), "VilfredSikker/tunnel-vision#3")
        XCTAssertEqual(try label("https://github.com/VilfredSikker/tunnel-vision/issues/12"), "VilfredSikker/tunnel-vision#12")
        XCTAssertEqual(try label("https://github.com/VilfredSikker/tunnel-vision"), "VilfredSikker/tunnel-vision")
        XCTAssertEqual(try label("https://linear.app/reshape/issue/ENG-123/fix-the-thing"), "ENG-123")
        XCTAssertEqual(try label("https://www.example.com/"), "example.com")
        XCTAssertEqual(try label("https://substack.com/p/notes"), "substack.com/p/notes")
        XCTAssertEqual(try label("https://amberliu2.substack.com/p/what-i-learned"), "amberliu2.substack.com/…/what-i-lea…", "cut at 36")
        XCTAssertEqual(try label("https://docs.example.com/guides/v2/getting-started/setup"), "docs.example.com/…/setup")
        XCTAssertEqual(try label("https://docs.example.com/a/setup"), "docs.example.com/a/setup", "whole when it fits")
    }

    func testLinkTextSplitsOutLinksAndSkipsOtherSchemes() {
        let segments = LinkText.segments("Review github.com/a/b/pull/7 then mail")
        XCTAssertEqual(segments.map(\.text), ["Review ", "a/b#7", " then mail"])
        XCTAssertEqual(segments[1].url?.absoluteString, "https://github.com/a/b/pull/7")
        XCTAssertNil(segments[0].url)
        XCTAssertEqual(LinkText.readable("See https://docs.example.com/guides/v2/getting-started/setup"), "See docs.example.com/…/setup")
        XCTAssertEqual(LinkText.segments("Plain text").map(\.text), ["Plain text"])
        XCTAssertTrue(LinkText.segments("mail me@example.com").allSatisfy { $0.url == nil }, "mailto links are not opened")
    }

    func testNotesAndChecklistRoundTripAndOldArchivesDecode() throws {
        let task = TaskItem(title: "Weekly review", durationSeconds: 1500, notes: "Inbox first",
                            checklist: [ChecklistItem(text: "Inbox", done: true), ChecklistItem(text: "Calendar")])
        let decoded = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded, task)

        let old = """
        {"id":"\(UUID().uuidString)","title":"Old","durationSeconds":1500,"overrides":[],"doneDays":[]}
        """
        let legacy = try JSONDecoder().decode(TaskItem.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.notes, "")
        XCTAssertEqual(legacy.checklist, [])

        let item = try JSONDecoder().decode(ChecklistItem.self, from: Data(#"{"text":"Bare"}"#.utf8))
        XCTAssertEqual(item.text, "Bare")
        XCTAssertFalse(item.done)
    }

    func testRepeatedCopyKeepsDescriptionAndTicks() {
        let task = TaskItem(title: "Weekly review", durationSeconds: 1500, repeatDaily: true, notes: "Inbox first",
                            checklist: [ChecklistItem(text: "Inbox", done: true), ChecklistItem(text: "Calendar")])
        let copy = task.repeatedCopy()
        XCTAssertEqual(copy.notes, "Inbox first")
        XCTAssertEqual(copy.checklist, task.checklist)
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
            countDay: "2026-09-02"
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
