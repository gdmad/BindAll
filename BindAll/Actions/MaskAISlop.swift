import Foundation

/// Normalizes "AI slop" typography so generated text looks like a human typed it:
/// em/en dashes → hyphen, smart quotes/apostrophes → straight, and emoji / stray unicode removed.
enum MaskAISlop {
    static func apply(to input: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(input.unicodeScalars.count)
        // Set when a scalar was stripped right after a space: the next space is swallowed so a
        // removal never leaves a doubled space ("hi 😀 there" -> "hi there"), while pre-existing
        // runs of spaces (indentation, column alignment) survive untouched.
        var strippedAfterSpace = false

        for scalar in input.unicodeScalars {
            if shouldStrip(scalar) {
                if scalars.last == " " { strippedAfterSpace = true }
                continue
            }

            switch scalar {
            // Dashes → hyphen-minus
            case "\u{2014}", // — em dash
                 "\u{2013}", // – en dash
                 "\u{2012}", // ‒ figure dash
                 "\u{2015}", // ― horizontal bar
                 "\u{2212}": // − minus sign
                scalars.append("-")

            // Double quotes → straight "
            case "\u{201C}", "\u{201D}", // “ ”
                 "\u{201E}", "\u{201F}", // „ ‟
                 "\u{00AB}", "\u{00BB}", // « »
                 "\u{2033}":             // ″
                scalars.append("\"")

            // Single quotes / apostrophes → straight '
            case "\u{2018}", "\u{2019}", // ‘ ’
                 "\u{201A}", "\u{201B}", // ‚ ‛
                 "\u{2032}":             // ′
                scalars.append("'")

            // Ellipsis → three dots
            case "\u{2026}":
                scalars.append(contentsOf: "...".unicodeScalars)

            // Non-breaking / thin spaces → regular space
            case " ", "\u{00A0}", "\u{2009}", "\u{202F}", "\u{2007}":
                if strippedAfterSpace {
                    strippedAfterSpace = false
                    continue
                }
                scalars.append(" ")

            default:
                scalars.append(scalar)
            }
            strippedAfterSpace = false
        }

        return String(scalars)
    }

    private static func shouldStrip(_ scalar: Unicode.Scalar) -> Bool {
        // Keep tab/newline/carriage return.
        if scalar == "\t" || scalar == "\n" || scalar == "\r" { return false }

        let props = scalar.properties
        if props.isEmoji && scalar.value > 0x238C { return true } // emoji (skip basic ASCII overlap)
        if props.isEmojiPresentation || props.isEmojiModifier || props.isEmojiModifierBase { return true }

        switch props.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator,
             .nonspacingMark, .enclosingMark,
             .otherSymbol:
            return true
        default:
            // Variation selectors / zero-width joiners.
            if (0xFE00...0xFE0F).contains(scalar.value) { return true }
            if scalar.value == 0x200D || scalar.value == 0x200B || scalar.value == 0x200C { return true }
            return false
        }
    }
}
