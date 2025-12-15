import AppKit
import Foundation

class MarkdownTextView: NSTextView {
    private var isUpdatingFormatting = false
    private var storedBaseFontSize: CGFloat = 14
    private var paletteTextColor: NSColor?
    private var paletteBackgroundColor: NSColor?

    private var selectedLineIndices: Set<Int> = []
    private var cachedTokens: [MarkdownToken] = []
    private var isSwappingText = false

    private var _sourceText: String = ""

    var sourceString: String {
        get { return _sourceText }
        set {
            _sourceText = newValue
            syncDisplayFromSource()
        }
    }

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

    // This is called when a change is made to the text. It has the chars changed and where.
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

    // This callback is called whenever the text is edited.
    override func didChangeText() {
        super.didChangeText()
        if !isUpdatingFormatting && !isSwappingText {
            syncSourceFromDisplay()
            DispatchQueue.main.async { [weak self] in
                self?.updateMarkdownFormatting()
            }
        }
    }

    // This callback is called whenever the cursor is moved.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !isUpdatingFormatting && !isSwappingText {
            updateSelectedLines()
        }
    }

    private func updateMarkdownFormatting() {
        guard textStorage != nil else { return }
        isUpdatingFormatting = true
        defer { isUpdatingFormatting = false }

        cachedTokens = MarkdownParser.parse(_sourceText).tokens
        rebuildDisplayText()
    }

    // This func and the next func are doing the reverse of each other.
    // This is from the external world to the display.
    private func syncDisplayFromSource() {
        guard let textStorage = textStorage else { return }
        isSwappingText = true
        defer { isSwappingText = false }

        cachedTokens = MarkdownParser.parse(_sourceText).tokens

        let displayText = buildDisplayString()

        textStorage.beginEditing()
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.replaceCharacters(in: fullRange, with: displayText)
        textStorage.endEditing()

        rebuildDisplayText()
    }

    // This is from display to the external world.
    private func syncSourceFromDisplay() {
        let displayText = string
        var sourceText = ""
        var displayIndex = 0

        for token in cachedTokens {
            let tokenLineIndex = lineIndex(forCharacterIndex: token.startI, in: _sourceText)
            let isLineSelected = selectedLineIndices.contains(tokenLineIndex)
            let usesRendered = token.tType == .HEADER && !isLineSelected && !token.rendered.isEmpty

            let displayTokenLength = usesRendered ? token.rendered.count : token.contents.count
            let displayTokenEnd = displayIndex + displayTokenLength

            if displayIndex < displayText.count {
                let startIdx = displayText.index(displayText.startIndex, offsetBy: displayIndex)
                let endIdx = displayText.index(displayText.startIndex, offsetBy: min(displayTokenEnd, displayText.count))
                let displayedToken = String(displayText[startIdx ..< endIdx])

                if usesRendered {
                    let prefixLength = token.contents.count - token.rendered.count
                    let prefix = String(token.contents.prefix(prefixLength))
                    sourceText += prefix + displayedToken
                } else {
                    sourceText += displayedToken
                }
            }

            displayIndex = displayTokenEnd
        }

        if displayIndex < displayText.count {
            let startIdx = displayText.index(displayText.startIndex, offsetBy: displayIndex)
            sourceText += String(displayText[startIdx...])
        }

        _sourceText = sourceText
    }

    private func buildDisplayString() -> String {
        var displayText = ""

        for token in cachedTokens {
            let tokenLineIndex = lineIndex(forCharacterIndex: token.startI, in: _sourceText)
            let isLineSelected = selectedLineIndices.contains(tokenLineIndex)

            if token.tType == .HEADER && !isLineSelected && !token.rendered.isEmpty {
                displayText += token.rendered
            } else {
                displayText += token.contents
            }
        }

        return displayText
    }

    // This is the primary rendering function.
    // Gets called if the external world changes, or if the selection changes.
    private func rebuildDisplayText() {
        guard let textStorage = textStorage else { return }

        isSwappingText = true
        defer { isSwappingText = false }

        let cursorPos = selectedRange().location
        let displayText = buildDisplayString()

        textStorage.beginEditing()
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.replaceCharacters(in: fullRange, with: displayText)
        resetAllFormatting(textStorage: textStorage)

        var displayOffset = 0
        for token in cachedTokens {
            let tokenLineIndex = lineIndex(forCharacterIndex: token.startI, in: _sourceText)
            let isLineSelected = selectedLineIndices.contains(tokenLineIndex)
            let usesRendered = token.tType == .HEADER && !isLineSelected && !token.rendered.isEmpty

            let displayLength = usesRendered ? token.rendered.count : token.contents.count
            let displayRange = NSRange(location: displayOffset, length: displayLength)

            guard displayRange.location >= 0 && NSMaxRange(displayRange) <= displayText.count else {
                displayOffset += displayLength
                continue
            }

            applyTokenFormatting(token: token, range: displayRange, to: textStorage)
            displayOffset += displayLength
        }
        textStorage.endEditing()

        let newCursorPos = min(cursorPos, textStorage.length)
        setSelectedRange(NSRange(location: newCursorPos, length: 0))
    }

    private func updateSelectedLines() {
        let newSelectedLines = computeSelectedLines()

        if newSelectedLines != selectedLineIndices {
            selectedLineIndices = newSelectedLines
            rebuildDisplayText()
        }
    }

    private func computeSelectedLines() -> Set<Int> {
        var lines = Set<Int>()
        let displayText = string

        for rangeValue in selectedRanges {
            let range = rangeValue.rangeValue

            let startLine = lineIndex(forCharacterIndex: range.location, in: displayText)
            lines.insert(startLine)

            if range.length > 0 {
                let endLine = lineIndex(forCharacterIndex: min(range.location + range.length, displayText.count), in: displayText)
                for line in startLine ... endLine {
                    lines.insert(line)
                }
            }
        }

        return lines
    }

    private func lineIndex(forCharacterIndex charIndex: Int, in text: String) -> Int {
        var lineCount = 0
        var currentIndex = 0

        for char in text {
            if currentIndex >= charIndex {
                break
            }
            if char == "\n" {
                lineCount += 1
            }
            currentIndex += 1
        }

        return lineCount
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
