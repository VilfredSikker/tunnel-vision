import Darwin
import Foundation

/// Signals that would otherwise kill Tunnel Vision with apps still frozen.
/// SIGPIPE is ignored outright (a vanished socket client costs an EPIPE);
/// TERM, HUP and INT run the handler on the main queue so the lock can be
/// released before the process exits. SIGKILL and crashes cannot be caught;
/// the victim store covers those on the next launch.
@MainActor
final class TerminationSignals {
    nonisolated static let handled: [Int32] = [SIGTERM, SIGHUP, SIGINT]

    private var sources: [DispatchSourceSignal] = []

    /// - Parameter signals: the app passes `handled`; tests pass a signal
    ///   that is harmless to the test process.
    func install(signals: [Int32] = handled, onSignal: @escaping @MainActor (_ signal: Int32) -> Void) {
        signal(SIGPIPE, SIG_IGN)
        for number in signals {
            // The default action must be off before the source exists, or
            // the signal kills the process before the handler runs.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { onSignal(number) }
            }
            source.resume()
            sources.append(source)
        }
    }
}
