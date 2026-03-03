import AppKit

class HidingLayoutManager: NSLayoutManager {
    /// Set of character indices that should be visually hidden.
    var hiddenCharIndices: Set<Int> = []

    /// Character indices where the glyph should be substituted with a bullet `•`.
    var bulletCharIndices: Set<Int> = []

    /// When true, draws a border around every token range for debugging.
    var debugTokenBorders = false

    /// When true, hides bounding boxes for PLAIN tokens in debug mode.
    var debugHidePlain = false

    /// Token debug info populated by MarkdownTextView.
    var debugTokens: [(range: NSRange, label: String)] = []

    private static let debugColors: [NSColor] = [
        .systemRed, .systemBlue, .systemOrange, .systemPurple,
    ]

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard debugTokenBorders, let tc = textContainers.first else { return }

        let labelFont = NSFont.systemFont(ofSize: 8, weight: .medium)

        for (i, token) in debugTokens.enumerated() {
            if debugHidePlain && token.label == "PLAIN" { continue }
            let color = Self.debugColors[i % Self.debugColors.count]
            let glyphRange = self.glyphRange(forCharacterRange: token.range, actualCharacterRange: nil)
            guard glyphRange.location != NSNotFound else { continue }
            let rect = boundingRect(forGlyphRange: glyphRange, in: tc)
            var adjusted = rect
            adjusted.origin.x += origin.x
            adjusted.origin.y += origin.y

            color.setStroke()
            let path = NSBezierPath(roundedRect: adjusted, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.0
            path.stroke()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: color,
            ]
            let labelStr = NSAttributedString(string: token.label, attributes: attrs)
            let labelSize = labelStr.size()
            let labelOrigin = NSPoint(
                x: adjusted.maxX - labelSize.width,
                y: adjusted.minY - labelSize.height
            )
            labelStr.draw(at: labelOrigin)
        }
    }

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

        for i in 0 ..< count {
            let charIdx = charIndexes[i]
            if hiddenCharIndices.contains(charIdx) {
                modifiedProps[i] = .null
            } else if bulletCharIndices.contains(charIdx) {
                modifiedGlyphs[i] = bulletGlyph
            }
        }

        modifiedGlyphs.withUnsafeBufferPointer { glyphBuf in
            modifiedProps.withUnsafeBufferPointer { propBuf in
                super.setGlyphs(glyphBuf.baseAddress!,
                                properties: propBuf.baseAddress!,
                                characterIndexes: charIndexes,
                                font: aFont,
                                forGlyphRange: glyphRange)
            }
        }
    }
}
