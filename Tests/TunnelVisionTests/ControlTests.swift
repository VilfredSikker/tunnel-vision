import TunnelVisionControlKit
import Foundation
import XCTest

@testable import TunnelVision

/// The control API against a real model on a temp archive.
@MainActor
final class ControlAPITests: XCTestCase {
    private var url: URL!
    private var now = Date(timeIntervalSince1970: 1_752_000_000)
    private var model: AppState!
    private var api: ControlAPI!

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TunnelVisionControl-\(UUID().uuidString)")
            .appendingPathComponent("data.json")
        model = AppState(fileURL: url, clock: { [weak self] in self?.now ?? Date() }, autoTick: false)
        var quiet = model.settings
        quiet.soundOn = false
        model.updateSettings(quiet)
        api = ControlAPI(model: model)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        try api.handle(method: method, params: params)
    }

    private func task(_ result: [String: Any]) -> [String: Any] {
        result["task"] as? [String: Any] ?? [:]
    }

    func testTasksAddListUpdateDoneDelete() throws {
        let added = task(try call("tasks.add", [
            "title": "  Write docs ",
            "duration_minutes": 40,
            "preset": "coding",
            "rules": [["bundle_id": "com.apple.finder"], ["bundle_id": "com.apple.Safari", "scope": "url", "pattern": "docs.rs"]],
        ]))
        XCTAssertEqual(added["title"] as? String, "Write docs")
        XCTAssertEqual(added["duration_minutes"] as? Int, 40)
        XCTAssertEqual((added["preset"] as? [String: Any])?["name"] as? String, "Coding", "preset names match case-insensitively")
        XCTAssertEqual((added["rules"] as? [[String: Any]])?.count, 2)
        XCTAssertGreaterThan((added["effective_rules"] as? [[String: Any]])?.count ?? 0, 2, "preset rules plus the task's own")
        XCTAssertEqual(added["done"] as? Bool, false)
        let id = added["id"] as! String

        let listed = try call("tasks.list")
        let tasks = listed["tasks"] as? [[String: Any]] ?? []
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0]["position"] as? Int, 0)
        XCTAssertEqual(listed["day"] as? String, model.todayKey)

        let updated = task(try call("tasks.update", ["id": id, "title": "Write the docs", "preset": "", "duration_minutes": 15]))
        XCTAssertEqual(updated["title"] as? String, "Write the docs")
        XCTAssertTrue(updated["preset"] is NSNull, "an empty preset detaches it")
        XCTAssertEqual(model.tasks[0].durationSeconds, 15 * 60)

        let done = task(try call("tasks.set_done", ["id": id]))
        XCTAssertEqual(done["done"] as? Bool, true)
        XCTAssertNotNil(done["done_at"])
        let undone = task(try call("tasks.set_done", ["id": id, "done": false]))
        XCTAssertEqual(undone["done"] as? Bool, false)

        XCTAssertEqual(try call("tasks.delete", ["id": id])["deleted"] as? String, id)
        XCTAssertTrue(model.tasks.isEmpty)
    }

    func testRulesResolveAppNamesAndRejectIncompleteOnes() throws {
        let added = task(try call("tasks.add", [
            "title": "Browse",
            "rules": [["app": "Safari", "scope": "url", "pattern": "github.com"]],
        ]))
        let rules = added["rules"] as? [[String: Any]] ?? []
        XCTAssertEqual(rules.first?["bundle_id"] as? String, "com.apple.Safari", "an installed app's name resolves to its bundle id")
        XCTAssertEqual(rules.first?["scope"] as? String, "url")

        XCTAssertThrowsError(try call("tasks.add", ["title": "Bad", "rules": [["bundle_id": "com.apple.dt.Xcode", "scope": "window"]]])) { error in
            XCTAssertEqual((error as? ControlError)?.code, ControlError.invalidParams("").code, "a window rule needs a pattern")
        }
        XCTAssertThrowsError(try call("tasks.add", ["title": "Bad", "rules": [["app": "Definitely Not An App 42"]]]))
        XCTAssertThrowsError(try call("tasks.add", ["rules": []])) { error in
            XCTAssertEqual((error as? ControlError)?.message, "title is required")
        }
        XCTAssertThrowsError(try call("tasks.add", ["title": "Long", "duration_minutes": 0]))
        XCTAssertThrowsError(try call("tasks.add", ["title": "X", "preset": "No such preset"])) { error in
            XCTAssertEqual((error as? ControlError)?.code, ControlError.notFound("").code)
        }
    }

    func testMinutesParamRejectsHugeAndNonFiniteDoublesInsteadOfTrapping() throws {
        // A finite double beyond Int.max (1e308) would trap a plain Int()
        // conversion and crash the app; it must come back as a clean error.
        XCTAssertThrowsError(try call("tasks.add", ["title": "Big", "duration_minutes": 1e308])) { error in
            XCTAssertEqual((error as? ControlError)?.code, ControlError.invalidParams("").code)
        }
        XCTAssertThrowsError(try call("tasks.add", ["title": "NaN", "duration_minutes": Double.nan])) { error in
            XCTAssertEqual((error as? ControlError)?.code, ControlError.invalidParams("").code)
        }
    }

    func testReorderPutsTheGivenTasksFirst() throws {
        _ = task(try call("tasks.add", ["title": "A"]))
        let b = task(try call("tasks.add", ["title": "B"]))["id"] as! String
        let c = task(try call("tasks.add", ["title": "C"]))["id"] as! String
        _ = try call("tasks.reorder", ["ids": [c, b]])
        XCTAssertEqual(model.tasks.map(\.title), ["C", "B", "A"])
        XCTAssertThrowsError(try call("tasks.reorder", ["ids": []]))
        XCTAssertThrowsError(try call("tasks.reorder", ["ids": ["not-an-id"]]))
    }

    func testPresetsCreateUpdateDelete() throws {
        let created = try call("presets.create", [
            "name": "Agent work",
            "mode": "frozen",
            "rules": [["bundle_id": "com.apple.Terminal"], ["bundle_id": "com.apple.Safari", "scope": "url", "pattern": "github.com/org"]],
            "urls_to_open": ["https://github.com/org"],
        ])["preset"] as? [String: Any] ?? [:]
        XCTAssertEqual(created["mode"] as? String, "frozen")
        XCTAssertEqual((created["rules"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(created["urls_to_open"] as? [String], ["https://github.com/org"])
        XCTAssertThrowsError(try call("presets.create", ["name": "agent WORK"]), "names are unique, case-insensitively")

        let updated = try call("presets.update", [
            "preset": "Agent work",
            "name": "Agent",
            "mode": "dark",
            "rules": [["bundle_id": "com.apple.Terminal"]],
        ])["preset"] as? [String: Any] ?? [:]
        XCTAssertEqual(updated["name"] as? String, "Agent")
        XCTAssertEqual(updated["mode"] as? String, "dark")
        XCTAssertEqual((updated["rules"] as? [[String: Any]])?.count, 1)

        XCTAssertThrowsError(try call("presets.update", ["preset": "Coding", "name": "Programming"])) { error in
            XCTAssertEqual((error as? ControlError)?.code, ControlError.refused("").code, "built-ins keep their name")
        }
        let coding = try call("presets.update", ["preset": "Coding", "mode": "closed"])["preset"] as? [String: Any]
        XCTAssertEqual(coding?["mode"] as? String, "closed", "but their mode and rules can change")

        XCTAssertEqual((try call("presets.list")["presets"] as? [[String: Any]])?.count, 5)
        _ = try call("presets.delete", ["preset": "Agent"])
        XCTAssertNil(model.preset(named: "Agent"))
        XCTAssertThrowsError(try call("presets.delete", ["preset": "Agent"]))
    }

    func testSessionFlow() throws {
        let id = task(try call("tasks.add", ["title": "Focus", "duration_minutes": 25]))["id"] as! String
        _ = task(try call("tasks.add", ["title": "Later"]))

        var state = try call("state.get")["state"] as? [String: Any] ?? [:]
        XCTAssertEqual(state["phase"] as? String, "idle")
        XCTAssertEqual((state["next_up"] as? [String: Any])?["title"] as? String, "Focus")

        state = try call("session.start", ["id": id])["state"] as? [String: Any] ?? [:]
        XCTAssertEqual(state["phase"] as? String, "work")
        XCTAssertEqual(state["remaining_seconds"] as? Int, 25 * 60)
        XCTAssertEqual((state["active_task"] as? [String: Any])?["id"] as? String, id)
        XCTAssertEqual((state["next_up"] as? [String: Any])?["title"] as? String, "Later")
        XCTAssertThrowsError(try call("session.start", ["id": id]), "one session at a time")

        XCTAssertEqual((try call("session.pause")["state"] as? [String: Any])?["phase"] as? String, "paused")
        XCTAssertThrowsError(try call("session.pause"))
        XCTAssertEqual((try call("session.resume")["state"] as? [String: Any])?["phase"] as? String, "work")
        XCTAssertEqual((try call("session.extend", ["minutes": 5])["state"] as? [String: Any])?["remaining_seconds"] as? Int, 30 * 60)
        XCTAssertThrowsError(try call("tasks.delete", ["id": id]), "the running task stays")

        XCTAssertEqual((try call("session.done")["state"] as? [String: Any])?["phase"] as? String, "break")
        XCTAssertEqual(model.todayCount, 1)
        XCTAssertEqual((try call("session.skip_break")["state"] as? [String: Any])?["phase"] as? String, "idle")
        XCTAssertThrowsError(try call("session.stop"))
    }

    func testUnknownMethodAndBadIds() {
        XCTAssertThrowsError(try call("nope.nothing")) { error in
            XCTAssertEqual((error as? ControlError)?.code, -32601)
        }
        XCTAssertThrowsError(try call("tasks.update", ["id": "not-a-uuid"])) { error in
            XCTAssertEqual((error as? ControlError)?.code, ControlError.notFound("").code)
        }
        XCTAssertThrowsError(try call("tasks.list", ["day": "yesterday"])) { error in
            XCTAssertEqual((error as? ControlError)?.code, ControlError.invalidParams("").code)
        }
    }
}

/// Wire format, MCP plumbing and tool routing, without the app.
final class ControlKitTests: XCTestCase {
    func testRequestAndResponseLinesRoundTrip() throws {
        let request = ControlProtocol.request(id: 7, method: "tasks.add", params: ["title": "X"])
        XCTAssertEqual(request.last, 0x0A, "one line per message")
        let parsed = ControlProtocol.parseRequest(request.dropLast())
        XCTAssertEqual(parsed?.method, "tasks.add")
        XCTAssertEqual(parsed?.id as? Int, 7)
        XCTAssertEqual(parsed?.params["title"] as? String, "X")
        XCTAssertNil(ControlProtocol.parseRequest(Data("{\"id\":1}".utf8)), "a request needs a method")

        let ok = try ControlProtocol.parseResponse(ControlProtocol.response(id: 7, result: ["n": 1]).dropLast())
        XCTAssertEqual(ok["n"] as? Int, 1)
        XCTAssertThrowsError(try ControlProtocol.parseResponse(ControlProtocol.errorResponse(id: 7, error: .notFound("gone")).dropLast())) { error in
            XCTAssertEqual(error as? ControlError, .server(code: -32001, message: "gone"))
        }
    }

    private func json(_ text: String?) -> [String: Any] {
        guard let text, let data = text.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testMCPHandshakeToolsAndCalls() {
        var calls: [(String, [String: Any])] = []
        let server = MCPServer(name: "anchor", version: "1", tools: ControlTools.all) { tool, args in
            calls.append((tool, args))
            return MCPToolResult(text: "ok:\(tool)")
        }

        let initialized = json(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#))
        let initResult = initialized["result"] as? [String: Any]
        XCTAssertEqual(initResult?["protocolVersion"] as? String, "2025-03-26", "a supported version is echoed")
        XCTAssertEqual((initResult?["serverInfo"] as? [String: Any])?["name"] as? String, "anchor")
        XCTAssertNotNil((initResult?["capabilities"] as? [String: Any])?["tools"])
        let odd = json(server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual((odd["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.supportedVersions[0])

        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "notifications get no reply")

        let list = json(server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        let tools = (list["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, ControlTools.all.count)
        let addTask = tools.first { $0["name"] as? String == "tunnelvision_add_task" }
        XCTAssertEqual((addTask?["inputSchema"] as? [String: Any])?["required"] as? [String], ["title"])

        let called = json(server.handle(line: #"{"jsonrpc":"2.0","id":"c1","method":"tools/call","params":{"name":"tunnelvision_add_task","arguments":{"title":"Docs"}}}"#))
        XCTAssertEqual(called["id"] as? String, "c1")
        let content = (called["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "ok:tunnelvision_add_task")
        XCTAssertEqual((called["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.1["title"] as? String, "Docs")

        let unknownTool = json(server.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"tunnelvision_fly"}}"#))
        XCTAssertEqual((unknownTool["error"] as? [String: Any])?["code"] as? Int, -32602)
        let unknownMethod = json(server.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#))
        XCTAssertEqual((unknownMethod["error"] as? [String: Any])?["code"] as? Int, -32601)
        let garbage = json(server.handle(line: "not json"))
        XCTAssertEqual((garbage["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertNotNil(json(server.handle(line: #"{"jsonrpc":"2.0","id":6,"method":"ping"}"#))["result"])
    }

    func testToolRoutes() {
        XCTAssertEqual(ControlTools.route(tool: "tunnelvision_add_task", arguments: ["title": "X"])?.method, "tasks.add")
        let session = ControlTools.route(tool: "tunnelvision_session", arguments: ["action": "start", "task_id": "abc"])
        XCTAssertEqual(session?.method, "session.start")
        XCTAssertEqual(session?.params["id"] as? String, "abc")
        XCTAssertNil(ControlTools.route(tool: "tunnelvision_session", arguments: ["task_id": "abc"]),
                     "a session tool call without an action must not silently start a session")
        let extend = ControlTools.route(tool: "tunnelvision_session", arguments: ["action": "extend", "minutes": 5])
        XCTAssertEqual(extend?.method, "session.extend")
        XCTAssertEqual(extend?.params["minutes"] as? Int, 5)
        XCTAssertNil(ControlTools.route(tool: "tunnelvision_fly", arguments: [:]))
        XCTAssertEqual(Set(ControlTools.all.map(\.name)).count, ControlTools.all.count, "tool names are unique")
        for tool in ControlTools.all {
            XCTAssertNotNil(ControlTools.route(tool: tool.name, arguments: ["action": "pause"]), "\(tool.name) routes somewhere")
        }
    }
}

/// The socket end to end: the app's listener answering a blocking client.
@MainActor
final class ControlSocketTests: XCTestCase {
    /// The blocking client must run off the main queue, which the server
    /// needs for its dispatch sources; JSON crosses the actor boundary.
    private func callDetached(_ client: ControlClient, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        let data: Data = try await Task.detached {
            let params = try JSONSerialization.jsonObject(with: paramsData) as? [String: Any] ?? [:]
            return try JSONSerialization.data(withJSONObject: client.call(method: method, params: params))
        }.value
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func testClientTalksToServerOverTheSocket() async throws {
        let path = NSTemporaryDirectory() + "tunnelvision-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(path: path) { method, params in
            guard method == "echo" else { throw ControlError.unknownMethod(method) }
            return ["echoed": params]
        }
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(server.isListening)

        let client = ControlClient(socketPath: path)
        XCTAssertTrue(client.isAvailable)
        let result = try await callDetached(client, "echo", ["n": 3, "s": "x"])
        let echoed = result["echoed"] as? [String: Any]
        XCTAssertEqual(echoed?["n"] as? Int, 3)
        XCTAssertEqual(echoed?["s"] as? String, "x")

        do {
            _ = try await callDetached(client, "nope")
            XCTFail("unknown methods come back as errors")
        } catch {
            XCTAssertEqual(error as? ControlError, .server(code: -32601, message: "unknown method nope"))
        }

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the socket file goes with the listener")
        do {
            _ = try await callDetached(client, "echo")
            XCTFail("nothing listens any more")
        } catch ControlError.unavailable {
            // expected
        }
    }
}
