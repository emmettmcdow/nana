import Foundation

// MARK: - Markdown Parsing Data Structures

struct MarkdownElement {
    let start: Int
    let end: Int
    let type: ElementType
    
    enum ElementType {
        case header(level: Int)
        case paragraph
        case quote
        case codeBlock
    }
}

struct MarkdownStyle {
    let start: Int
    let end: Int
    let type: StyleType
    
    enum StyleType {
        case bold
        case italic
        case inlineCode
    }
}

struct MarkdownFormatting {
    let elements: [MarkdownElement]
    let styles: [MarkdownStyle]
}

// MARK: - Stub Parser (Replace with Zig integration)

class StubMarkdownParser {
    static func parse(_ text: String) -> MarkdownFormatting {
        var elements: [MarkdownElement] = []
        var styles: [MarkdownStyle] = []
        
        let lines = text.components(separatedBy: .newlines)
        var currentPosition = 0
        
        for line in lines {
            let lineStart = currentPosition
            let lineEnd = currentPosition + line.count
            
            // Parse headers
            if line.hasPrefix("# ") {
                elements.append(MarkdownElement(start: lineStart, end: lineEnd, type: .header(level: 1)))
            } else if line.hasPrefix("## ") {
                elements.append(MarkdownElement(start: lineStart, end: lineEnd, type: .header(level: 2)))
            } else if line.hasPrefix("### ") {
                elements.append(MarkdownElement(start: lineStart, end: lineEnd, type: .header(level: 3)))
            } else if line.hasPrefix("> ") {
                elements.append(MarkdownElement(start: lineStart, end: lineEnd, type: .quote))
            } else if line.hasPrefix("```") {
                // Simple code block detection (would need more sophisticated logic)
                elements.append(MarkdownElement(start: lineStart, end: lineEnd, type: .codeBlock))
            } else if !line.isEmpty {
                elements.append(MarkdownElement(start: lineStart, end: lineEnd, type: .paragraph))
            }
            
            // Parse inline styles
            parseInlineStyles(line, baseOffset: lineStart, styles: &styles)
            
            currentPosition = lineEnd + 1 // +1 for newline character
        }
        
        return MarkdownFormatting(elements: elements, styles: styles)
    }
    
    private static func parseInlineStyles(_ text: String, baseOffset: Int, styles: inout [MarkdownStyle]) {
        let nsString = text as NSString
        
        // Parse **bold**
        let boldPattern = "\\*\\*([^*]+)\\*\\*"
        if let boldRegex = try? NSRegularExpression(pattern: boldPattern) {
            let matches = boldRegex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                let range = match.range(at: 1) // Capture group (text between **)
                styles.append(MarkdownStyle(
                    start: baseOffset + range.location - 2, // Include ** in range
                    end: baseOffset + range.location + range.length + 2,
                    type: .bold
                ))
            }
        }
        
        // Parse *italic*
        let italicPattern = "(?<!\\*)\\*([^*]+)\\*(?!\\*)"
        if let italicRegex = try? NSRegularExpression(pattern: italicPattern) {
            let matches = italicRegex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                let range = match.range(at: 1) // Capture group
                styles.append(MarkdownStyle(
                    start: baseOffset + range.location - 1, // Include * in range
                    end: baseOffset + range.location + range.length + 1,
                    type: .italic
                ))
            }
        }
        
        // Parse `inline code`
        let codePattern = "`([^`]+)`"
        if let codeRegex = try? NSRegularExpression(pattern: codePattern) {
            let matches = codeRegex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                let range = match.range(at: 1) // Capture group
                styles.append(MarkdownStyle(
                    start: baseOffset + range.location - 1, // Include ` in range
                    end: baseOffset + range.location + range.length + 1,
                    type: .inlineCode
                ))
            }
        }
    }
}