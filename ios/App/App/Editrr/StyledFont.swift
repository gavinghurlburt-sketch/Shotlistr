import CoreText
import SwiftUI
import UIKit

/// Bold and italic on any font. A font's own bold or italic face is used when it has one;
/// otherwise the letters are drawn heavier, or slanted, so the buttons always do something.
///
/// It travels as a "font spec": the PostScript name with "|b", "|i" or "|bi" on the end (no
/// name before the bar means the system font). Plain text has no bar, so it's the name as before.
enum StyledFont {
    /// How slanted a made-up italic is.
    static let slant = 12.0 * Double.pi / 180
    /// How much heavier a made-up bold is (a stroke in the letters' own color, percent of the size).
    static let boldStroke = 3.5

    static func spec(_ postScript: String?, bold: Bool, italic: Bool) -> String? {
        guard bold || italic else { return postScript }
        return (postScript ?? "") + "|" + (bold ? "b" : "") + (italic ? "i" : "")
    }

    struct Made {
        let font: CTFont
        /// Drawn heavier: the font has no bolder face of its own.
        let fakeBold: Bool
        /// Slanted by hand: the font has no italic of its own.
        let slanted: Bool
    }

    private static let lock = NSLock()
    /// Per spec: which face to use and what to make up (worked out once per font).
    nonisolated(unsafe) private static var faces: [String: (face: UIFontDescriptor?, fakeBold: Bool, slanted: Bool)] = [:]

    static func font(_ spec: String?, size: CGFloat) -> Made {
        var name = spec
        var bold = false, italic = false
        if let spec, let bar = spec.lastIndex(of: "|") {
            let flags = spec[spec.index(after: bar)...]
            bold = flags.contains("b")
            italic = flags.contains("i")
            let before = String(spec[..<bar])
            name = before.isEmpty ? nil : before
        }
        let base = name.flatMap { UIFont(name: $0, size: size) } ?? UIFont.systemFont(ofSize: size, weight: .black)
        guard bold || italic else { return Made(font: base as CTFont, fakeBold: false, slanted: false) }

        let key = spec ?? ""
        lock.lock()
        var known = faces[key]
        lock.unlock()
        if known == nil {
            let had = base.fontDescriptor.symbolicTraits
            var want = had
            if bold { want.insert(.traitBold) }
            if italic { want.insert(.traitItalic) }
            var found: UIFont?
            if want != had, let descriptor = base.fontDescriptor.withSymbolicTraits(want) {
                let styled = UIFont(descriptor: descriptor, size: size)
                // Some fonts hand back themselves: only a different face counts.
                if styled.fontName != base.fontName { found = styled }
            }
            let got = found?.fontDescriptor.symbolicTraits ?? had
            // Already bold (like the system's black) or no bold face: drawn heavier instead.
            let fakeBold = bold && (had.contains(.traitBold) || !got.contains(.traitBold))
            let slanted = italic && !got.contains(.traitItalic)
            known = (found?.fontDescriptor, fakeBold, slanted)
            lock.lock()
            if faces.count > 200 { faces.removeAll() }
            faces[key] = known
            lock.unlock()
        }
        guard let face = known else { return Made(font: base as CTFont, fakeBold: false, slanted: false) }
        // The face kept as a descriptor: the system font's faces can't be opened by name.
        let picked = face.face.map { UIFont(descriptor: $0, size: size) } ?? base
        var font = picked as CTFont
        if face.slanted {
            var matrix = CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(slant)), d: 1, tx: 0, ty: 0)
            font = CTFontCreateWithFontDescriptor(CTFontCopyFontDescriptor(picked as CTFont), size, &matrix)
        }
        return Made(font: font, fakeBold: face.fakeBold, slanted: face.slanted)
    }
}

/// Bold and Italic: two buttons that stay lit while on.
struct BoldItalicRow: View {
    let bold: Bool
    let italic: Bool
    let toggleBold: () -> Void
    let toggleItalic: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggleBold) {
                Image(systemName: "bold").frame(width: 22)
            }
            .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: bold))
            .accessibilityLabel("Bold")
            .accessibilityAddTraits(bold ? .isSelected : [])
            Button(action: toggleItalic) {
                Image(systemName: "italic").frame(width: 22)
            }
            .buttonStyle(GlassButtonStyle(tint: Tint.accent, selected: italic))
            .accessibilityLabel("Italic")
            .accessibilityAddTraits(italic ? .isSelected : [])
            Spacer(minLength: 0)
        }
    }
}
