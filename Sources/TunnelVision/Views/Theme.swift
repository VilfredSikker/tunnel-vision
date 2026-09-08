import SwiftUI

/// Palette: one accent for allowed/positive, one muted red for blocked/destructive,
/// neutral everything else. Quiet assistant tone — no gamified colours.
enum Theme {
    /// Accent for allowed / running / positive actions.
    static let allowed = Color(nsColor: .systemGreen)
    /// Muted red for blocked / stop.
    static let blocked = Color(red: 0.78, green: 0.28, blue: 0.29)

    static func ringFraction(_ fraction: Double) -> Double {
        min(max(fraction, 0), 1)
    }
}
