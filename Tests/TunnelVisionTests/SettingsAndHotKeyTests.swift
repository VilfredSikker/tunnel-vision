import AppKit
import Carbon.HIToolbox
import XCTest

@testable import TunnelVision

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
        XCTAssertNil(settings.newTaskHotKey)
        XCTAssertNil(settings.startPauseHotKey)
        XCTAssertNil(settings.pickerHotKey)
        XCTAssertTrue(settings.showCountdownWindow, "the floating countdown defaults on")
        XCTAssertEqual(settings.unmanagedBrowsers, [], "every supported browser is managed until switched off")
    }

    func testSettingsRoundTripKeepsShortcutsCountdownAndBrowsers() throws {
        var settings = Settings()
        settings.toggleHotKey = HotKey(keyCode: 35, carbonModifiers: HotKey.command | HotKey.option, keyLabel: "P")
        settings.newTaskHotKey = HotKey(keyCode: 45, carbonModifiers: HotKey.command | HotKey.option, keyLabel: "N")
        settings.startPauseHotKey = HotKey(keyCode: 49, carbonModifiers: HotKey.command | HotKey.option, keyLabel: "Space")
        settings.pickerHotKey = HotKey(keyCode: 14, carbonModifiers: HotKey.command | HotKey.option, keyLabel: "E")
        settings.showCountdownWindow = false
        settings.unmanagedBrowsers = ["com.google.Chrome"]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.newTaskHotKey?.display, "⌥⌘N")
        XCTAssertEqual(decoded.startPauseHotKey?.display, "⌥⌘Space")
    }

    func testHotKeysBySlotSkipUnsetOnes() {
        var settings = Settings()
        settings.pickerHotKey = HotKey(keyCode: 14, carbonModifiers: HotKey.command, keyLabel: "E")
        XCTAssertEqual(settings.hotKeys, [.openPicker: settings.pickerHotKey!])
        settings.startPauseHotKey = HotKey(keyCode: 49, carbonModifiers: HotKey.command, keyLabel: "Space")
        XCTAssertEqual(settings.hotKeys.count, 2)
    }

    func testHotKeySlotsHaveDistinctCarbonIDs() {
        let ids = HotKeyCenter.Slot.allCases.map(\.rawValue)
        XCTAssertEqual(Set(ids).count, ids.count, "each shortcut needs its own id to be told apart when fired")
        XCTAssertEqual(HotKeyCenter.Slot(rawValue: 2), .newTask)
        XCTAssertEqual(HotKeyCenter.Slot(rawValue: 3), .startPause)
        XCTAssertEqual(HotKeyCenter.Slot(rawValue: 4), .openPicker)
    }

    func testBrowsersManagedByDefault() {
        XCTAssertTrue(Browsers.supports("net.imput.helium"))
        XCTAssertTrue(Browsers.supports("com.apple.Safari"))
        XCTAssertFalse(Browsers.supports("org.mozilla.firefox"), "Firefox exposes no tabs to scripting")
        XCTAssertEqual(Browsers.managed(unmanaged: []), Browsers.supported)
        XCTAssertFalse(Browsers.managed(unmanaged: ["com.google.Chrome"]).contains("com.google.Chrome"))
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
