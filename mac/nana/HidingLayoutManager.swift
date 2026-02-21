import AppKit

class HidingLayoutManager: NSLayoutManager {
    /// Set of character indices that should be visually hidden.
    var hiddenCharIndices: Set<Int> = []

    /// Character indices where the glyph should be substituted with a bullet `•`.
    var bulletCharIndices: Set<Int> = []

    /// Call after updating hiddenCharIndices and bulletCharIndices.
    func applyChanges(oldHidden: Set<Int>, oldBullets: Set<Int>) {
        guard let textStorage = textStorage, textStorage.length > 0 else { return }

        let allChanged = oldHidden.symmetricDifference(hiddenCharIndices)
            .union(oldBullets.symmetricDifference(bulletCharIndices))
        guard !allChanged.isEmpty else { return }

        let lo = allChanged.min()!
        let hi = allChanged.max()!
        let range = NSRange(location: lo, length: hi - lo + 1)

        invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
    }

    override func setGlyphs(
        _ glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) {
        let count = glyphRange.length
        var modifiedProps = Array(UnsafeBufferPointer(start: props, count: count))
        var modifiedGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))

        var bulletGlyph: CGGlyph = 0
        var bulletChar: UniChar = 0x2022
        CTFontGetGlyphsForCharacters(aFont, &bulletChar, &bulletGlyph, 1)

        for i in 0..<count {
            let charIdx = charIndexes[i]
            if hiddenCharIndices.contains(charIdx) {
                modifiedProps[i] = .null
            } else if bulletCharIndices.contains(charIdx) {
                modifiedGlyphs[i] = bulletGlyph
            }
        }

        modifiedGlyphs.withUnsafeBufferPointer { glyphBuf in
            modifiedProps.withUnsafeBufferPointer { propBuf in
                super.setGlyphs(glyphBuf.baseAddress!, properties: propBuf.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            }
        }
    }
}
