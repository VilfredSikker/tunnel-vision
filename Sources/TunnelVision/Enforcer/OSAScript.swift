import Foundation

/// Runs AppleScript through `osascript`, off the main thread. Nil on any
/// failure, including a declined Automation prompt. Callers put a
/// `with timeout` in the script so a stalled browser cannot hang them.
enum OSAScript {
    static func run(_ source: String) async -> String? {
        // Cancellation-aware: the detached task owns the child process, so a
        // cancelled poll (session ended mid-sweep) kills osascript instead of
        // leaving it to run out its timeout on a stranded thread.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { () -> String? in
                do {
                    try process.run()
                } catch {
                    return nil
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                return String(data: data, encoding: .utf8)
            }.value
        } onCancel: {
            process.terminate()
        }
    }

    /// A Swift string as an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
