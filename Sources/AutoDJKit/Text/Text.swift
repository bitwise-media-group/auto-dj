// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import Foundation

/// The string formatting the reports need, counted in Unicode scalars like Python's slicing
/// and format widths (port of internal/text).
public enum Text {
    /// The first n characters of s (Python's s[:n]).
    public static func truncate(_ s: String, _ n: Int) -> String {
        var u = String.UnicodeScalarView()
        u.append(contentsOf: s.unicodeScalars.prefix(n))
        return String(u)
    }

    /// s padded with spaces to n characters (Python's f"{s:<n}").
    public static func padRight(_ s: String, _ n: Int) -> String {
        let c = s.unicodeScalars.count
        return c < n ? s + String(repeating: " ", count: n - c) : s
    }

    /// s right-aligned in n characters (Python's f"{s:>n}").
    public static func padLeft(_ s: String, _ n: Int) -> String {
        let c = s.unicodeScalars.count
        return c < n ? String(repeating: " ", count: n - c) + s : s
    }

    static func isLetter(_ r: Unicode.Scalar) -> Bool {
        switch r.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    static func isDigit(_ r: Unicode.Scalar) -> Bool {
        r.properties.generalCategory == .decimalNumber
    }

    /// Go's unicode.IsNumber (Nd, Nl, No).
    static func isNumber(_ r: Unicode.Scalar) -> Bool {
        switch r.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    /// Go's unicode.IsSpace.
    static func isSpace(_ r: Unicode.Scalar) -> Bool {
        switch r.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0: return true
        default: return r.value > 0xFF && r.properties.isWhitespace
        }
    }

    /// A folder name from s: lower case, each run of anything but letters and digits turned
    /// into one '-' ("Melodic Dark (Live)" -> "melodic-dark-live"); "set" when nothing is left.
    public static func slug(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var dash = false
        for r in s.lowercased().unicodeScalars {
            if isLetter(r) || isDigit(r) {
                if dash, !out.isEmpty { out.append("-") }
                out.append(r)
                dash = false
            } else {
                dash = true
            }
        }
        return out.isEmpty ? "set" : String(out)
    }

    /// s made safe as one path element on macOS, Windows and Linux: Unicode NFC, runs of white
    /// space collapsed to one space, path and reserved characters (/ \ : * ? " < > |) and
    /// control characters replaced by '_', no leading dot or trailing dots and spaces, at most
    /// 200 bytes (cut on a character boundary).
    public static func fileName(_ s: String) -> String {
        var b = String.UnicodeScalarView()
        var space = false
        for var r in s.precomposedStringWithCanonicalMapping.unicodeScalars {
            if isSpace(r) {
                space = !b.isEmpty
                continue
            }
            if "/\\:*?\"<>|".unicodeScalars.contains(r) || r.properties.generalCategory == .control {
                r = "_"
            }
            if space {
                b.append(" ")
                space = false
            }
            b.append(r)
        }
        var scalars = Array(b)
        while let f = scalars.first, f == "." { scalars.removeFirst() }
        while let l = scalars.last, l == "." || l == " " { scalars.removeLast() }
        var out = String(String.UnicodeScalarView(scalars))
        while out.utf8.count > 200 {
            out.unicodeScalars.removeLast()
        }
        return out.isEmpty ? "_" : out
    }
}
