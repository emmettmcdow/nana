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
        isRichText = true
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        usesFindBar = true
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

    override func didChangeText() {
        super.didChangeText()


        if !isUpdatingFormatting {
            updateMarkdownFormatting()
        }
    }

    private func updateMarkdownFormatting() {
        guard let textStorage = textStorage else { return }

        isUpdatingFormatting = true
        defer { isUpdatingFormatting = false }

        let text = string
        let formatting = MarkdownParser.parse(text)

        // Clear existing attributes but preserve text
        let fullRange = NSRange(location: 0, length: text.count)
        textStorage.removeAttribute(.font, range: fullRange)
        textStorage.removeAttribute(.foregroundColor, range: fullRange)
        textStorage.removeAttribute(.backgroundColor, range: fullRange)
        textStorage.removeAttribute(.paragraphStyle, range: fullRange)

        // Apply default styling - use the stored font size instead of the potentially changing font property
        let baseFontSize = storedBaseFontSize
        let defaultFont = NSFont.systemFont(ofSize: baseFontSize)
        let defaultColor = textColor ?? NSColor.textColor

        textStorage.addAttribute(.font, value: defaultFont, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: defaultColor, range: fullRange)

        // Apply token formatting
        for token in formatting.tokens {
            let range = NSRange(location: token.startI, length: token.endI - token.startI)
            guard range.location >= 0 && NSMaxRange(range) <= text.count else { continue }

            applyTokenFormatting(token: token, range: range, to: textStorage)
        }

        // Set typing attributes to use the correct base font and color
        typingAttributes = [
            .font: defaultFont,
            .foregroundColor: defaultColor,
        ]
    }

    private func applyTokenFormatting(token: MarkdownToken, range: NSRange, to textStorage: NSTextStorage) {
        let defaultColor = textColor ?? NSColor.textColor
        let baseFontSize = font?.pointSize ?? 14

        switch token.tType {
        case .HEADER:
            let fontSize: CGFloat
            switch token.degree {
            case 1: fontSize = baseFontSize * 1.714 // 24/14 ratio
            case 2: fontSize = baseFontSize * 1.429 // 20/14 ratio
            case 3: fontSize = baseFontSize * 1.214 // 17/14 ratio
            case 4: fontSize = baseFontSize * 1.143 // 16/14 ratio
            case 5: fontSize = baseFontSize * 1.071 // 15/14 ratio
            case 6: fontSize = baseFontSize * 1.0 // 14/14 ratio
            default: fontSize = baseFontSize
            }

            let headerFont = NSFont.boldSystemFont(ofSize: fontSize)
            textStorage.addAttribute(.font, value: headerFont, range: range)
            textStorage.addAttribute(.foregroundColor, value: defaultColor, range: range)

        case .PLAIN:
            // Default formatting (already applied)
            break

        case .QUOTE:
            let quoteFont = NSFont.systemFont(ofSize: baseFontSize)
            let quoteColor = NSColor.secondaryLabelColor

            // Create paragraph style with left indent
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = 20
            paragraphStyle.headIndent = 20

            textStorage.addAttribute(.font, value: quoteFont, range: range)
            textStorage.addAttribute(.foregroundColor, value: quoteColor, range: range)
            textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)

        case .BLOCK_CODE:
            let codeFont = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.857, weight: .regular) // 12/14 ratio
            // Use palette colors but make them slightly darker
            let originalBackground = paletteBackgroundColor ?? NSColor.textBackgroundColor
            let originalForeground = paletteTextColor ?? NSColor.textColor

            // Darken the background slightly for code blocks
            let codeBackgroundColor = originalBackground.blended(withFraction: 0.15, of: NSColor.black) ?? originalBackground
            let codeTextColor = originalForeground

            // Extend background one character past the token to include any following newline
            var backgroundRange = range
            if NSMaxRange(range) < string.count {
                backgroundRange = NSRange(location: range.location, length: range.length + 1)
            }

            textStorage.addAttribute(.font, value: codeFont, range: range)
            textStorage.addAttribute(.backgroundColor, value: codeBackgroundColor, range: backgroundRange)
            textStorage.addAttribute(.foregroundColor, value: codeTextColor, range: range)

        case .BOLD:
            if let currentFont = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                let boldFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
                textStorage.addAttribute(.font, value: boldFont, range: range)
            }

        case .ITALIC:
            if let currentFont = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                let italicFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .italicFontMask)
                textStorage.addAttribute(.font, value: italicFont, range: range)
            }

        case .CODE:
            let codeFont = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.929, weight: .regular) // 13/14 ratio
            let backgroundColor = NSColor.controlBackgroundColor

            textStorage.addAttribute(.font, value: codeFont, range: range)
            textStorage.addAttribute(.backgroundColor, value: backgroundColor, range: range)

        case .UNORDERED_LIST:
            // Handle list formatting - no additional indentation, tabs in content are sufficient
            let listFont = NSFont.systemFont(ofSize: baseFontSize)

            textStorage.addAttribute(.font, value: listFont, range: range)
            textStorage.addAttribute(.foregroundColor, value: defaultColor, range: range)

        case .ORDERED_LIST:
            // Handle ordered list formatting - no additional indentation, tabs in content are sufficient
            let listFont = NSFont.systemFont(ofSize: baseFontSize)

            textStorage.addAttribute(.font, value: listFont, range: range)
            textStorage.addAttribute(.foregroundColor, value: defaultColor, range: range)

        case .EMPHASIS:
            // Triple emphasis (bold + italic)
            if let currentFont = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                let boldItalicFont = NSFontManager.shared.convert(currentFont, toHaveTrait: [.boldFontMask, .italicFontMask])
                textStorage.addAttribute(.font, value: boldItalicFont, range: range)
            }

        case .HORZ_RULE:
            // Could add special formatting for horizontal rules
            let ruleColor = NSColor.separatorColor
            textStorage.addAttribute(.foregroundColor, value: ruleColor, range: range)
        }
    }

    // Public method to force formatting update (useful for external triggers)
    func refreshMarkdownFormatting() {
        updateMarkdownFormatting()
    }

    // Method to update the base font size
    func updateBaseFontSize(_ fontSize: CGFloat) {
        storedBaseFontSize = fontSize
    }

    // Methods to store palette colors
    func setPaletteColors(textColor: NSColor, backgroundColor: NSColor) {
        paletteTextColor = textColor
        paletteBackgroundColor = backgroundColor
        insertionPointColor = textColor // Set cursor color to match foreground color
    }
}
