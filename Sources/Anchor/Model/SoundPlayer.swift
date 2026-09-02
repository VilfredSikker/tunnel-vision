import AppKit
import Foundation

/// Small system sounds. Calm by design: one chime at session end, a softer
/// one when the break is over.
@MainActor
enum SoundPlayer {
    static func sessionEnd() {
        play("Glass")
    }

    static func breakEnd() {
        play("Pop")
    }

    static func error() {
        play("Basso")
    }

    private static func play(_ name: String) {
        if let sound = NSSound(named: NSSound.Name(name)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }

    /// Light haptic tick, used when a press threshold completes.
    static func hapticTick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}
