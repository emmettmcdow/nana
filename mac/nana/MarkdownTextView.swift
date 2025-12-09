import AppKit
import Foundation

class MarkdownTextView: NSTextView {
    private var isUpdatingFormatting = false
    private var storedBaseFontSize: CGFloat = 14
    private var paletteTextColor: NSColor?
    private var paletteBackgroundColor: NSColor?

    override func awakeFromNib() {
        super.awakeFromNib()
        setupTextView()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        setupTextView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTextView()
    }

    private func setupTextView() {
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = false
        usesFontPanel = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = NSSize(width: 8, height: 8)
        isEditable = true
        isSelectable = true

        // Set default font
        font = NSFont.systemFont(ofSize: 14)

        // Ensure the text container is properly configured
        if let container = textContainer {
            container.lineFragmentPadding = 10 // Add padding to help with background rendering
        }
    }

    override var frame: NSRect {
        didSet {
            // Update text container width when frame changes
            if let container = textContainer {
                container.containerSize = NSSize(width: frame.width, height: CGFloat.greatestFiniteMagnitude)
            }
        }
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        return super.becomeFirstResponder()
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // Set typing attributes from previous character before insertion
        if !isUpdatingFormatting, affectedCharRange.location > 0, let textStorage = textStorage {
            let prevLocation = affectedCharRange.location - 1
            if prevLocation < textStorage.length {
                let attrs = textStorage.attributes(at: prevLocation, effectiveRange: nil)
                typingAttributes = attrs
            }
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func didChangeText() {
        super.didChangeText()
        if !isUpdatingFormatting {
            DispatchQueue.main.async { [weak self] in
                self?.updateMarkdownFormatting()
            }
        }
    }

    private func updateMarkdownFormatting() {
        guard let textStorage = textStorage else { return }
        isUpdatingFormatting = true
        defer { isUpdatingFormatting = false }

        let text = string
        let formatting = MarkdownParser.parse(text)

        textStorage.beginEditing()
        defer { textStorage.endEditing() }
        resetAllFormatting(textStorage: textStorage)
        for token in formatting.tokens {
            let range = NSRange(location: token.startI, length: token.endI - token.startI)
            guard range.location >= 0 && NSMaxRange(range) <= text.count else { continue }
            applyTokenFormatting(token: token, range: range, to: textStorage)
        }
    }

    private func resetAllFormatting(textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: string.count)
        let baseFontSize = storedBaseFontSize
        let defaultFont = NSFont.systemFont(ofSize: baseFontSize)
        let defaultColor = textColor ?? NSColor.textColor
        let defaultParagraphStyle = NSParagraphStyle.default

        // Set all default attributes in one batched operation
        let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: defaultFont,
            .foregroundColor: defaultColor,
            .backgroundColor: NSColor.clear, // Explicitly set transparent background
            .paragraphStyle: defaultParagraphStyle,
        ]

        textStorage.setAttributes(defaultAttributes, range: fullRange)
        typingAttributes = [
            .font: defaultFont,
            .foregroundColor: defaultColor,
        ]
    }

    private func applyTokenFormatting(token: MarkdownToken, range: NSRange, to textStorage: NSTextStorage) {
        var attributes: [NSAttributedString.Key: Any] = [:]
        var mod_range: NSRange = range
        let defaultColor = textColor ?? NSColor.textColor
        let baseFontSize = storedBaseFontSize

        let codeFont = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
        let listFont = NSFont.systemFont(ofSize: baseFontSize)
        let quoteFont = NSFont.systemFont(ofSize: baseFontSize)

        switch token.tType {
        case .HEADER:
            let fontSize: CGFloat
            switch token.degree {
            case 1: fontSize = baseFontSize * (24.0 / 14.0)
            case 2: fontSize = baseFontSize * (20.0 / 14.0)
            case 3: fontSize = baseFontSize * (17.0 / 14.0)
            case 4: fontSize = baseFontSize * (16.0 / 14.0)
            case 5: fontSize = baseFontSize * (15.0 / 14.0)
            case 6: fontSize = baseFontSize * (14.0 / 14.0)
            default: fontSize = baseFontSize
            }

            let headerFont = NSFont.boldSystemFont(ofSize: fontSize)

            attributes[.font] = headerFont
            attributes[.foregroundColor] = defaultColor

        case .PLAIN:
            // Default formatting (already applied)
            return

        case .QUOTE:
            let quoteColor = NSColor.secondaryLabelColor

            // Create paragraph style with left indent
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = 20
            paragraphStyle.headIndent = 20

            attributes[.font] = quoteFont
            attributes[.foregroundColor] = quoteColor
            attributes[.paragraphStyle] = paragraphStyle

        case .BLOCK_CODE:
            // Use palette colors but make them slightly darker
            let originalBackground = paletteBackgroundColor ?? NSColor.textBackgroundColor
            let originalForeground = paletteTextColor ?? NSColor.textColor

            // Darken the background slightly for code blocks
            let codeBackgroundColor = originalBackground.blended(withFraction: 0.15, of: NSColor.black) ?? originalBackground
            let codeTextColor = originalForeground

            attributes[.font] = codeFont
            attributes[.foregroundColor] = codeTextColor
            attributes[.backgroundColor] = codeBackgroundColor

            if NSMaxRange(range) < string.count {
                mod_range = NSRange(location: range.location, length: range.length + 1)
            }

        case .BOLD:
            if let currentFont = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                let boldFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
                attributes[.font] = boldFont
            }

        case .ITALIC:
            if let currentFont = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                let italicFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .italicFontMask)
                attributes[.font] = italicFont
            }

        case .CODE:
            // Use palette colors but make them slightly darker
            let originalBackground = paletteBackgroundColor ?? NSColor.textBackgroundColor
            let originalForeground = paletteTextColor ?? NSColor.textColor
            // Darken the background slightly for code blocks
            let codeBackgroundColor = originalBackground.blended(withFraction: 0.15, of: NSColor.black) ?? originalBackground
            let codeTextColor = originalForeground

            attributes[.font] = codeFont
            attributes[.foregroundColor] = codeTextColor
            attributes[.backgroundColor] = codeBackgroundColor

        case .UNORDERED_LIST:
            attributes[.font] = listFont
            attributes[.foregroundColor] = defaultColor

        case .ORDERED_LIST:
            attributes[.font] = listFont
            attributes[.foregroundColor] = defaultColor

        case .EMPHASIS:
            // Triple emphasis (bold + italic)
            if let currentFont = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                let boldItalicFont = NSFontManager.shared.convert(currentFont, toHaveTrait: [.boldFontMask, .italicFontMask])
                attributes[.font] = boldItalicFont
            }

        case .HORZ_RULE:
            // Could add special formatting for horizontal rules
            let ruleColor = NSColor.separatorColor
            attributes[.foregroundColor] = ruleColor
        }

        // Apply all attributes in a single call
        if !attributes.isEmpty {
            textStorage.addAttributes(attributes, range: mod_range)
        }
    }

    func refreshMarkdownFormatting() {
        updateMarkdownFormatting()
    }

    func updateBaseFontSize(_ fontSize: CGFloat) {
        storedBaseFontSize = fontSize
    }

    func baseFontSize() -> CGFloat {
        return storedBaseFontSize
    }

    func setPalette(palette: Palette) {
        textColor = palette.NSfg()
        paletteTextColor = palette.NSfg()

        backgroundColor = palette.NSbg()
        paletteBackgroundColor = palette.NSbg()

        insertionPointColor = palette.NStert()
    }
}
