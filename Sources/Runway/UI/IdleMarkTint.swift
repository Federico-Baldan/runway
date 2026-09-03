import SwiftUI

/// What colour the resting mark is drawn in.
///
/// The mark is the one piece of Runway that is on screen when there is nothing
/// to report — for hours at a time, on the one part of the display nobody can
/// move it off. That is a long time to look at somebody else's taste, which is
/// why this is a preference and the position is too.
///
/// ## Why a short list and not a colour well
///
/// A free picker would let you choose a colour that cannot be seen. The mark
/// sits on the island's black, which under a real cutout is the same black as
/// the camera housing, and anything dark enough to be interesting against a
/// window background disappears entirely up there. Every option here is a hue
/// the app already trusts on that black: they are lifted straight from
/// `StatusPalette`, which exists precisely because the system semantics sit too
/// dark on it. Nothing new is invented, so nothing can drift.
///
/// Reusing the status hues cannot be misread as a status, either: the resting
/// mark is only ever on screen when nothing is running, so a green light and a
/// green run disc are never up at the same time.
public enum IdleMarkTint: String, Sendable, CaseIterable {
    /// The mark as it has always been drawn, and still the default: white, so
    /// it reads as a light rather than as a decoration.
    case white
    case blue
    case green
    case amber
    case red
    case violet
    case teal

    /// Name shown in Settings, as a colour and not as a status — you are
    /// picking a light, not subscribing to an outcome.
    public var title: String {
        switch self {
        case .white: return "White"
        case .blue: return "Blue"
        case .green: return "Green"
        case .amber: return "Amber"
        case .red: return "Red"
        case .violet: return "Violet"
        case .teal: return "Teal"
        }
    }

    /// The hue this tint is built from, or `nil` for the achromatic default.
    private var hue: Color? {
        switch self {
        case .white: return nil
        case .blue: return StatusPalette.running
        case .green: return StatusPalette.success
        case .amber: return StatusPalette.approval
        case .red: return StatusPalette.failure
        case .violet: return StatusPalette.environment(.production)
        case .teal: return StatusPalette.environment(.staging)
        }
    }

    /// The light in the middle of the mark.
    ///
    /// Carried a little heavier when it is coloured. White at 78% is the
    /// brightest thing this shape can be; a saturated hue at the same alpha
    /// lands well under it in perceived luminance and reads as a dimmed lamp
    /// rather than a coloured one. 90% puts it back where white sits, and the
    /// attentive state still has somewhere to go above it.
    func light(isAttentive: Bool) -> Color {
        guard let hue else { return .white.opacity(isAttentive ? 0.95 : 0.78) }
        return hue.opacity(isAttentive ? 1 : 0.90)
    }

    /// The shell around it: found rather than noticed, in every tint.
    ///
    /// Two points above the white version, for the same reason the light is —
    /// at this alpha a hue is darker than the white it replaces, and the shell
    /// is already at the edge of what can be seen. It stays a hint: under a
    /// cutout the black around the mark is hardware, and anything with real
    /// contrast up there reads as a rendering fault.
    var shell: Color {
        guard let hue else { return .white.opacity(0.13) }
        return hue.opacity(0.15)
    }

    /// The glow under the light. A touch stronger when coloured — on black it
    /// is the halo, not the disc, that says which colour this is at 16 points.
    var glow: Color {
        guard let hue else { return .white.opacity(0.30) }
        return hue.opacity(0.42)
    }

    /// Full strength, for the swatches in Settings, where the background is a
    /// window and not the notch.
    var swatch: Color { hue ?? .white }
}
