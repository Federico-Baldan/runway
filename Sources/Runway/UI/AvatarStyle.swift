#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Which face the resting mark wears.
///
/// The animator does not care. Every one of these is drawn from the same four
/// numbers the original eye is — how shut the lid is, where it is looking, how
/// wide it is open, how bright the light is — so a new face is a new *renderer*
/// and never a new behaviour: it blinks, looks around, nods, dozes and wakes
/// exactly when and how often the eye does, and on battery it spends exactly
/// what the eye spends. What a face may add is one **signature**, a short
/// gesture that only it makes (see `HelmetSignature`), and the animator draws
/// that on the same budget as everything else.
///
/// The helmets are drawn flat, in the way an icon set draws one: a few tones,
/// one accent, the detail made of cut-outs and hairlines, and no glow or blur
/// anywhere. That is a choice about looks and also about cost — there is
/// nothing here for the compositor to blur on every frame of a breath.
public enum AvatarStyle: String, Sendable, CaseIterable {
    /// The eye the mark has always had.
    case classic
    /// Graphite shell, orange band, a gold sun visor that is also the eyelid.
    case apollo
    /// A round window, a silver visor, a red band, a lamp and a camera.
    case orlan
    /// Nearly black, one white pinstripe, an iridium-blue visor.
    case stealth
    /// Black with a papaya band, a white pinstripe, a seven and a visor with a
    /// notch for the nose.
    case papaya
    /// Matt gunmetal, hi-vis chevrons, a sun strip that never goes away.
    case endurance

    /// How tall the mark is drawn in the resting band, in points.
    ///
    /// A helmet has far more in it than the eye, so at the eye's 16 points it
    /// shrinks to a few readable things and a dark smudge. 24 gives every
    /// design unit a third more room, and the band under the cutout grows by
    /// the same amount (it is as tall as its row).
    public var restHeight: CGFloat { isHelmet ? 24 : 16 }

    /// The same in the row that shows when the island is hovered, which is 32
    /// points tall.
    public var hoverHeight: CGFloat { isHelmet ? 20 : 13 }

    /// What a fresh install wears. One line to change.
    public static let `default`: AvatarStyle = .apollo

    /// The name shown in Settings.
    public var title: String {
        switch self {
        case .classic: return "Eye"
        case .apollo: return "Apollo"
        case .orlan: return "Orlan"
        case .stealth: return "Stealth"
        case .papaya: return "Papaya"
        case .endurance: return "Endurance"
        }
    }

    /// One line for the tooltip.
    public var summary: String {
        switch self {
        case .classic:
            return "The original: a notch with a light in it that blinks and looks around."
        case .apollo:
            return "Graphite helmet with an orange band. The gold visor is the eyelid: it "
                + "rests as a strip and drops to blink. Now and then it lifts and taps back, "
                + "a light runs along the band, a glint slides over the gold, or the side latches light."
        case .orlan:
            return "Round window and a silver visor. The lamp flashes and the camera focuses, "
                + "a light runs round the porthole, the eyes glance at the camera as it clicks, or the "
                + "lamp's beam sweeps the face."
        case .stealth:
            return "Almost black, with one white line and a blue visor. Now and then a "
                + "glint sweeps the glass while the eyes track it, a line scans the window, "
                + "the eyes read down the glass, or targeting brackets close on one eye."
        case .papaya:
            return "Racing helmet in black and papaya with a number seven. The tear-off "
                + "tab flicks and the sun visor dips, the number shines, the eyes shiver "
                + "like an engine, or it winks."
        case .endurance:
            return "Gunmetal endurance helmet with hi-vis chevrons. A pit-lane strobe "
                + "flashes the chevrons and the number, the sun strip dips, a light "
                + "runs along the chevrons, or a glare fills the visor."
        }
    }

    /// Everything but the original eye is a helmet.
    public var isHelmet: Bool { self != .classic }
}
