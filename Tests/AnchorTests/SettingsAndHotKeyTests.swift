import AppKit
import Carbon.HIToolbox
import XCTest

@testable import Anchor

final class SettingsAndHotKeyTests: XCTestCase {
    func testSettingsDecodeFromArchiveWithoutNewKeys() throws {
        let json = """
        {"workSeconds":1500,"breakSeconds":300,"strictMode":true,"defaultMode":"frozen","soundOn":false}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.workSeconds, 1500)
        XCTAssertTrue(settings.strictMode)
        XCTAssertEqual(settings.defaultMode, .frozen)
        XCTAssertFalse(settings.soundOn)
        XCTAssertNil(settings.toggleHotKey, "older archives carry no shortcut")
        XCTAssertTrue(settings.showCountdownWindow, "the floating countdown defaults on")
    }

    func testSettingsRoundTripKeepsShortcutAndCountdown() throws {
        var settings = Settings()
        settings.toggleHotKey = HotKey(keyCode: 35, carbonModifiers: HotKey.command | HotKey.option, keyLabel: "P")
        settings.showCountdownWindow = false
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
    }

    func testHotKeyDisplayUsesSystemModifierOrder() {
        let all = HotKey(
            keyCode: 35,
            carbonModifiers: HotKey.command | HotKey.shift | HotKey.option | HotKey.control,
            keyLabel: "P"
        )
        XCTAssertEqual(all.display, "⌃⌥⇧⌘P")
        XCTAssertEqual(HotKey(keyCode: 49, carbonModifiers: HotKey.command, keyLabel: "Space").display, "⌘Space")
    }

    func testModifierBitsMatchCarbon() {
        XCTAssertEqual(HotKey.command, UInt32(cmdKey))
        XCTAssertEqual(HotKey.shift, UInt32(shiftKey))
        XCTAssertEqual(HotKey.option, UInt32(optionKey))
        XCTAssertEqual(HotKey.control, UInt32(controlKey))
        XCTAssertEqual(
            HotKeyDisplay.carbonModifiers(from: [.command, .shift, .capsLock, .function]),
            HotKey.command | HotKey.shift,
            "only the four shortcut modifiers translate"
        )
    }
}
