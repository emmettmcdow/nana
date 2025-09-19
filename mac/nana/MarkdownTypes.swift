import Foundation
#if DISABLE_NANAKIT
    func nana_search(_: String) -> String {
        return ""
    }
#else
    import NanaKit
#endif

enum TokenType: String, Codable {
    case HEADER
    case HORZ_RULE
    case QUOTE
    case ORDERED_LIST
    case UNORDERED_LIST
    case BOLD
    case ITALIC
    case EMPHASIS
    case CODE
    case BLOCK_CODE
    case PLAIN
}

struct MarkdownToken: Codable {
    let tType: TokenType
    let startI: Int
    let endI: Int
    let contents: String
    let degree: Int
    
    enum CodingKeys: String, CodingKey {
        case tType, startI, endI, contents, degree
    }
}

struct MarkdownFormatting {
    let tokens: [MarkdownToken]
}

class MarkdownParser {
    static func parse(_ text: String) -> MarkdownFormatting {
        guard let cString = text.cString(using: .utf8) else {
            return MarkdownFormatting(tokens: [])
        }
        
        let resultPointer = nana_parse_markdown(cString)
        guard let jsonCString = resultPointer else {
            return MarkdownFormatting(tokens: [])
        }
        
        let jsonString = String(cString: jsonCString)
        guard let jsonData = jsonString.data(using: .utf8) else {
            return MarkdownFormatting(tokens: [])
        }
        
        do {
            let tokens = try JSONDecoder().decode([MarkdownToken].self, from: jsonData)
            return MarkdownFormatting(tokens: tokens)
        } catch {
            print("Error parsing markdown JSON: \(error)")
            return MarkdownFormatting(tokens: [])
        }
    }
}
