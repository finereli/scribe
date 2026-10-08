import Foundation
import SwiftUI
import AppKit

extension View {
    /// Show the pointing-hand cursor on hover, the way clickable controls do.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    /// Show the text I-beam cursor on hover, signalling an editable field.
    func iBeamCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.iBeam.push() } else { NSCursor.pop() }
        }
    }

    /// Suppress the blue keyboard-focus ring on this control.
    @ViewBuilder
    func noFocusRing() -> some View {
        if #available(macOS 14.0, *) {
            focusEffectDisabled()
        } else {
            focusable(false)
        }
    }
}

/// Determines base writing direction from text content (first strong
/// directional character), so the transcript flows correctly regardless of
/// which language was selected.
enum TextDirection {
    static func isRTL(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Strong RTL: Hebrew, Arabic, Syriac, Thaana, and their
            // presentation forms.
            if (0x0590...0x05FF).contains(v) ||   // Hebrew
               (0x0600...0x06FF).contains(v) ||   // Arabic
               (0x0700...0x074F).contains(v) ||   // Syriac
               (0x0750...0x077F).contains(v) ||   // Arabic Supplement
               (0x0780...0x07BF).contains(v) ||   // Thaana
               (0x08A0...0x08FF).contains(v) ||   // Arabic Extended-A
               (0xFB1D...0xFB4F).contains(v) ||   // Hebrew presentation
               (0xFB50...0xFDFF).contains(v) ||   // Arabic presentation A
               (0xFE70...0xFEFF).contains(v) {     // Arabic presentation B
                return true
            }
            // Strong LTR: Latin/Greek/Cyrillic letters end the search.
            if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) ||
               (0x00C0...0x024F).contains(v) || (0x0370...0x03FF).contains(v) ||
               (0x0400...0x04FF).contains(v) {
                return false
            }
        }
        return false
    }
}
