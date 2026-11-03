// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// Every helmet after the first five: how it is drawn, what it does and what it
/// is a picture of, one `HelmetEntry` each.
///
/// The drawings live in `HelmetData*.swift`, a batch of four to a file, and are
/// added up here. `AvatarStyle.helmet` and `HelmetSignature.gestures(for:)` look
/// a style up in this table, so a helmet is a case in `AvatarStyle` and an entry
/// in a batch and nothing else; the spike fails a case that has no entry.
///
/// Built once, on first use: the picker and the animator both ask for a style at a
/// time, and the plain numbers of 27 helmets are a few thousand points.
enum HelmetCollection {
    static let entries: [AvatarStyle: HelmetEntry] = {
        var all: [AvatarStyle: HelmetEntry] = [:]
        for batch in [batch1, batch2, batch3, batch4, batch5, batch6] {
            for (style, entry) in batch { all[style] = entry }
        }
        return all
    }()
}
