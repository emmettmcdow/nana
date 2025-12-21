import AppKit
import Foundation

class MarkdownTextView: NSTextView {
    private var isUpdatingFormatting = false
    private var storedBaseFontSize: CGFloat = 14
    private var paletteTextColor: NSColor?
    private var paletteBackgroundColor: NSColor?
    private var currFormatting: MarkdownFormatting = .init(tokens: [])

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

        let text = string
        let new_formatting = MarkdownParser.parse(text)
        guard new_formatting.tokens.count > 0 else { return }

        if currFormatting.tokens.isEmpty {
            for token in new_formatting.tokens {
                let range = NSRange(location: token.startI, length: token.endI - token.startI)
                assert(range.location >= 0)
                assert(text.unicodeScalars.count > 0)
                assert(NSMaxRange(range) <= text.unicodeScalars.count)
                applyTokenFormatting(token: token, range: range, to: textStorage)
            }
            currFormatting = new_formatting
            return
        }

        // Check for the first differing token
        var first_changed_token_idx = 0
        for (i, new_tok) in new_formatting.tokens.enumerated() {
            first_changed_token_idx = i
            if i >= currFormatting.tokens.count || new_tok != currFormatting.tokens[i] {
                break
            }
        }

        // Check for the last differing token
        let length_change = new_formatting.tokens.last!.endI - currFormatting.tokens.last!.endI
        var end_offset_idx = 1
        for new_tok in new_formatting.tokens.reversed() {
            if end_offset_idx >= currFormatting.tokens.count {
                break
            }
            let old_tok = currFormatting.tokens[currFormatting.tokens.count - end_offset_idx]
            let old_tok_mod = MarkdownToken(
                tType: old_tok.tType,
                startI: old_tok.startI + length_change,
                endI: old_tok.endI + length_change,
                contents: old_tok.contents,
                degree: old_tok.degree
            )

            assert(old_tok_mod.startI >= 0 && old_tok_mod.startI <= text.unicodeScalars.count)
            assert(old_tok_mod.endI >= 0 && old_tok_mod.endI <= text.unicodeScalars.count)
            if new_tok != old_tok_mod {
                break
            }
            end_offset_idx += 1
        }
        let last_changed_token_idx = new_formatting.tokens.count - end_offset_idx

        if last_changed_token_idx < first_changed_token_idx {
            // No changes made
            return
        }

        isUpdatingFormatting = true
        textStorage.beginEditing()
        defer {
            currFormatting = new_formatting
            textStorage.endEditing()
            isUpdatingFormatting = false
        }

        let first_changed_str_idx = new_formatting.tokens[first_changed_token_idx].startI
        let last_changed_str_idx = new_formatting.tokens[last_changed_token_idx].endI
        let change_len = last_changed_str_idx - first_changed_str_idx
        let updatable_range = NSRange(location: first_changed_str_idx, length: change_len)
        resetFormattingForRange(textStorage: textStorage, range: updatable_range)
        for token in new_formatting.tokens[first_changed_token_idx ... last_changed_token_idx] {
            let range = NSRange(location: token.startI, length: token.endI - token.startI)
            assert(range.location >= 0)
            assert(text.unicodeScalars.count > 0)
            assert(NSMaxRange(range) <= text.unicodeScalars.count)
            applyTokenFormatting(token: token, range: range, to: textStorage)
        }
    }

    private func resetAllFormatting(textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: string.unicodeScalars.count)
        resetFormattingForRange(textStorage: textStorage, range: fullRange)
    }

    private func resetFormattingForRange(textStorage: NSTextStorage, range: NSRange) {
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

        textStorage.setAttributes(defaultAttributes, range: range)
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

            if NSMaxRange(range) < string.unicodeScalars.count {
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

            // https://stackoverflow.com/questions/11286674/horizontal-hr-like-separator-in-nsattributedstring
            // We likely need unicode support to  do this.
            // let hr = NSAttributedString(string: "\n\r\u{00A0} \u{0009} \u{00A0}\n\n", attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: UIColor.gray])

            let ruleColor = NSColor.separatorColor
            attributes[.foregroundColor] = ruleColor

        case .LINK:
            let linkColor = NSColor.linkColor
            attributes[.foregroundColor] = linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue

            if let urlString = extractURL(from: token.contents),
               let url = URL(string: urlString)
            {
                attributes[.link] = url
            }
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

    private func extractURL(from linkContent: String) -> String? {
        guard let openParen = linkContent.lastIndex(of: "("),
              let closeParen = linkContent.lastIndex(of: ")"),
              openParen < closeParen
        else {
            return nil
        }
        let urlStart = linkContent.index(after: openParen)
        return String(linkContent[urlStart ..< closeParen])
    }
}
