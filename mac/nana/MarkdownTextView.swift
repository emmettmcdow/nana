import AppKit
import Foundation

class MarkdownTextView: NSTextView {
    private var isUpdatingFormatting = false
    private var storedBaseFontSize: CGFloat = 14
    
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
            container.widthTracksTextView = true
            container.heightTracksTextView = false
            container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
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
        let formatting = StubMarkdownParser.parse(text)
        
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
        
        // Apply element formatting
        for element in formatting.elements {
            let range = NSRange(location: element.start, length: element.end - element.start)
            guard range.location >= 0 && NSMaxRange(range) <= text.count else { continue }
            
            applyElementFormatting(element: element, range: range, to: textStorage)
        }
        
        // Apply style formatting
        for style in formatting.styles {
            let range = NSRange(location: style.start, length: style.end - style.start)
            guard range.location >= 0 && NSMaxRange(range) <= text.count else { continue }
            
            applyStyleFormatting(style: style, range: range, to: textStorage)
        }
        
        // Set typing attributes to use the correct base font and color
        typingAttributes = [
            .font: defaultFont,
            .foregroundColor: defaultColor
        ]
    }
    
    private func applyElementFormatting(element: MarkdownElement, range: NSRange, to textStorage: NSTextStorage) {
        let defaultColor = textColor ?? NSColor.textColor
        let baseFontSize = font?.pointSize ?? 14
        
        switch element.type {
        case .header(let level):
            let fontSize: CGFloat
            switch level {
            case 1: fontSize = baseFontSize * 1.714  // 24/14 ratio
            case 2: fontSize = baseFontSize * 1.429  // 20/14 ratio  
            case 3: fontSize = baseFontSize * 1.214  // 17/14 ratio
            default: fontSize = baseFontSize
            }
            
            let headerFont = NSFont.boldSystemFont(ofSize: fontSize)
            textStorage.addAttribute(.font, value: headerFont, range: range)
            textStorage.addAttribute(.foregroundColor, value: defaultColor, range: range)
            
        case .paragraph:
            // Default paragraph formatting (already applied)
            break
            
        case .quote:
            let quoteFont = NSFont.systemFont(ofSize: baseFontSize)
            let quoteColor = NSColor.secondaryLabelColor
            
            // Create paragraph style with left indent
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.firstLineHeadIndent = 20
            paragraphStyle.headIndent = 20
            
            textStorage.addAttribute(.font, value: quoteFont, range: range)
            textStorage.addAttribute(.foregroundColor, value: quoteColor, range: range)
            textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
            
        case .codeBlock:
            let codeFont = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.857, weight: .regular) // 12/14 ratio
            let backgroundColor = NSColor.controlBackgroundColor
            
            textStorage.addAttribute(.font, value: codeFont, range: range)
            textStorage.addAttribute(.backgroundColor, value: backgroundColor, range: range)
            textStorage.addAttribute(.foregroundColor, value: defaultColor, range: range)
        }
    }
    
    private func applyStyleFormatting(style: MarkdownStyle, range: NSRange, to textStorage: NSTextStorage) {
        switch style.type {
        case .bold:
            if let currentFont = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                let boldFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
                textStorage.addAttribute(.font, value: boldFont, range: range)
            }
            
        case .italic:
            if let currentFont = textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
                let italicFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .italicFontMask)
                textStorage.addAttribute(.font, value: italicFont, range: range)
            }
            
        case .inlineCode:
            let baseFontSize = font?.pointSize ?? 14
            let codeFont = NSFont.monospacedSystemFont(ofSize: baseFontSize * 0.929, weight: .regular) // 13/14 ratio
            let backgroundColor = NSColor.controlBackgroundColor
            
            textStorage.addAttribute(.font, value: codeFont, range: range)
            textStorage.addAttribute(.backgroundColor, value: backgroundColor, range: range)
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
}