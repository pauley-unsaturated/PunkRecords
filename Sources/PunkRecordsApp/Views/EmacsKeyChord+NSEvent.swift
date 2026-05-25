import AppKit
import PunkRecordsCore

extension EmacsKeyChord {
    /// Build a chord from a key-down event, or nil if no Control/Option (Meta)
    /// modifier is held — i.e. not an Emacs chord. `charactersIgnoringModifiers`
    /// gives the base key (it ignores everything but Shift), so Option-f reads
    /// as "f" and C-w as "w". Control codes (and C-Space's NUL) are normalized
    /// back to their base character defensively.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        let control = flags.contains(.control)
        let meta = flags.contains(.option)
        guard control || meta else { return nil }
        guard var base = event.charactersIgnoringModifiers, !base.isEmpty else { return nil }

        if let scalar = base.unicodeScalars.first {
            if scalar.value == 0 {
                base = " "                                   // C-Space → NUL
            } else if (1...26).contains(scalar.value), let s = UnicodeScalar(scalar.value + 96) {
                base = String(s)                             // C-a…C-z control codes → a…z
            }
        }

        self.init(key: base.lowercased(), control: control, meta: meta)
    }
}
