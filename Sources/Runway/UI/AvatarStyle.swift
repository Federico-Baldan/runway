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

    // The helmets after the first five. Each one is a real object with a
    // silhouette of its own (`HelmetSpec.silhouette`), described and registered
    // in `HelmetCollection`; the raw values are stored, so they never change.

    /// Black fire helmet: a wide brim, a red front shield and a hood.
    case fire
    /// Brass diving helmet with a round front window.
    case diver
    /// Samurai kabuto with a crescent crest and a flared neck guard.
    case kabuto
    /// A flat-topped great helm with a cross-shaped eye slit.
    case greathelm
    /// American football helmet with a facemask cage.
    case gridiron
    /// Motocross helmet with a long peak and goggles.
    case moto
    /// Formula 1 helmet seen through the halo.
    case halo
    /// Leather flying helmet with goggles and ear flaps.
    case aviator
    /// Fixed-wing pilot's helmet with an oxygen mask.
    case fighter
    /// Miner's hard hat with a cap lamp and a respirator.
    case miner
    /// Auto-darkening welding helmet.
    case welder
    /// Corinthian bronze helm with a crest.
    case corinthian
    /// Kendo men with a steel grille and shoulder flaps.
    case kendo
    /// Murmillo gladiator helmet with a fin crest and a grille.
    case murmillo
    /// Hounskull bascinet with a pointed visor and mail.
    case bascinet
    /// Viking-age helmet with a spectacle guard.
    case gjermundbu
    /// Ski helmet with goggles and a gaiter.
    case ski
    /// Forestry helmet with ear defenders and a mesh visor.
    case forestry
    /// British police custodian helmet.
    case custodian
    /// Fencing mask with a mesh and a bib.
    case fencing
    /// Helicopter crew helmet with a boom microphone.
    case heli
    /// Jockey's helmet in quartered silks.
    case jockey

    /// How tall the mark is drawn in the resting band, in points.
    ///
    /// A helmet has far more in it than the eye, so at the eye's 16 points it
    /// shrinks to a few readable things and a dark smudge.
    ///
    /// It gets three more, and the band under the cutout does NOT grow with it:
    /// that band is drawn over whatever is behind it (a title bar, a tab row),
    /// every point of it is something the user cannot see while working, and 24
    /// points, which made it eight taller, was taken as covering their work. The
    /// helmet takes what the eye leaves as air below it instead; see
    /// `restBottomPadding`.
    ///
    /// Three points of air and not two: nested rounded shapes sit right when the
    /// inner radius is the outer one minus the gap (what SwiftUI's
    /// `ConcentricRectangle` computes), and the island's bottom corners are 18
    /// while a helmet's are half its height, so the gap that would nest them is
    /// about 8, which the band cannot afford. The nearer to that, the better.
    public var restHeight: CGFloat { isHelmet ? 19 : 16 }

    /// The row the mark sits in, and the air under it. Together 22 points for
    /// every face: the band is as tall as it always was.
    public var restRowHeight: CGFloat { isHelmet ? 19 : 17 }
    public var restBottomPadding: CGFloat { isHelmet ? 3 : 5 }

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
        case .fire: return "Fire"
        case .diver: return "Diver"
        case .kabuto: return "Kabuto"
        case .greathelm: return "Great helm"
        case .gridiron: return "Gridiron"
        case .moto: return "Motocross"
        case .halo: return "Halo"
        case .aviator: return "Aviator"
        case .fighter: return "Fighter"
        case .miner: return "Miner"
        case .welder: return "Welder"
        case .corinthian: return "Corinthian"
        case .kendo: return "Kendo"
        case .murmillo: return "Murmillo"
        case .bascinet: return "Bascinet"
        case .gjermundbu: return "Gjermundbu"
        case .ski: return "Ski"
        case .forestry: return "Forestry"
        case .custodian: return "Custodian"
        case .fencing: return "Fencing"
        case .heli: return "Heli"
        case .jockey: return "Jockey"
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
        case .fire:
            return "Black fire helmet with a red front shield. The shield catches a headlight, "
                + "the face shield dips, a light runs along the reflective brim, or the hood is pulled up."
        case .diver:
            return "Brass diving helmet. Bubbles leave the exhaust valve, the wing nuts light round "
                + "the collar, the front window swings half shut, or the spit cock turns."
        case .kabuto:
            return "Black samurai kabuto with a gold crescent. The crest catches the light, the "
                + "neck-guard lacing lights from the top, the wing flaps spread, or the brow plate scowls."
        case .greathelm:
            return "Flat-topped great helm with a cross-shaped slit. The cross bands flash, "
                + "the rivets run round the face, the visor slams down, or the breaths puff."
        case .gridiron:
            return "Football helmet with a blue stripe. A light runs down the stripe, the facemask "
                + "rattles, the chin strap snaps shut, or the eye shield comes down."
        case .moto:
            return "Motocross helmet with a yellow peak and goggles. A tear-off film is peeled "
                + "off the lenses, the peak lifts, the mouthpiece slides open, or the goggle tint drops."
        case .halo:
            return "Formula 1 helmet behind the halo. A light runs over the arch, the visor "
                + "flicks down, the radio crackles in the ear pods, or a light climbs the pillar."
        case .aviator:
            return "Leather flying helmet with brass goggles. The ear flaps flutter, the sun lenses "
                + "flip down, the chin-strap buckle catches the light, or the goggle brass flashes."
        case .fighter:
            return "Pilot's flight helmet with an oxygen mask. The sun visor comes down, the oxygen "
                + "flow runs along the hose, the receivers click, or the mask breathes."
        case .miner:
            return "Miner's hard hat with a cap lamp. The lamp flares, power runs along the cable, "
                + "the respirator cartridges turn, or the ribs of the crown light in turn."
        case .welder:
            return "Auto-darkening welding helmet. The sensors flash and the lens goes dark, the shade "
                + "dial turns, the power light blinks, or three tack welds light the lens."
        case .corinthian:
            return "Corinthian bronze helm with a red crest. The crest sways, a light runs down the "
                + "nasal bar, the brow frowns, or the helm slips down over the eyes."
        case .kendo:
            return "Indigo kendo men with a steel grille. The grille rings bar by bar, the shoulder flaps bob, the throat guard swings, or the stitching of the crown lights from the middle out."
        case .murmillo:
            return "Gladiator's helmet with a red fin. The fin catches the light, a light runs across the grille, the visor is slammed down, or the brim flashes as the crowd roars."
        case .bascinet:
            return "Pointed medieval bascinet with a mail curtain. The visor lifts on its pivots, a light runs down the mail, the breaths puff, or the tip of the skull catches the light."
        case .gjermundbu:
            return "Viking-age helmet with a guard round the eyes. The spectacles flash, the nose guard swings, a light runs through the mail, or the rivets of the band light in pairs."
        case .ski:
            return "Ski helmet with goggles. The vent slots light one by one, the ear pads flex, the buckle catches the light, or the lens tint comes down."
        case .forestry:
            return "Forestry helmet with ear defenders and a mesh visor. The defenders clamp in, a light runs across the mesh, the visor flips down, or the hi-vis band strobes."
        case .custodian:
            return "Police custodian helmet with a rose top. The rose catches the light, the front plate shines, the chin-strap buckle glints, or the brim tips down in a salute."
        case .fencing:
            return "Fencing mask with a violet bib. A hit registers on the bib, a light runs across the mesh, the crown strap is pulled tight, or the mask is lifted in a salute."
        case .heli:
            return "Helicopter crew helmet with a headset. The boom swings up from the mouth, the sun visor comes down, the ear cups flash on a call, or a light runs along the cord."
        case .jockey:
            return "Jockey's helmet in purple and gold silks. The pom bobs, the four quarters flash in turn, the goggles are pulled down, or the chin-strap buckle glints."
        }
    }

    /// Everything but the original eye is a helmet.
    public var isHelmet: Bool { self != .classic }

    /// The shelf it is on in Settings: with 20-odd faces a grid needs headings.
    public var family: AvatarFamily {
        switch self {
        case .classic: return .eye
        case .apollo, .orlan, .stealth: return .space
        case .papaya, .endurance, .moto, .halo: return .racing
        case .aviator, .fighter, .heli: return .sky
        case .fire, .diver, .miner, .welder, .forestry, .custodian: return .work
        case .gridiron, .kendo, .ski, .fencing, .jockey: return .sport
        case .kabuto, .greathelm, .corinthian, .murmillo, .bascinet, .gjermundbu: return .history
        }
    }
}

/// The headings of the face picker, in the order they are shown.
public enum AvatarFamily: String, Sendable, CaseIterable {
    case eye, space, racing, sky, work, sport, history

    public var title: String {
        switch self {
        case .eye: return "Eye"
        case .space: return "Space"
        case .racing: return "Racing"
        case .sky: return "Flying"
        case .work: return "Work"
        case .sport: return "Sport"
        case .history: return "History"
        }
    }

    /// The faces on this shelf, in declaration order.
    public var styles: [AvatarStyle] { AvatarStyle.allCases.filter { $0.family == self } }
}
