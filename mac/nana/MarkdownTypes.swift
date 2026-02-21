import Foundation

#if DISABLE_NANAKIT
    private func nana_parse_markdown(_: [Int8]) -> UnsafePointer<Int8>? {
        return nil
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
    case LINK
    case PLAIN
}

struct MarkdownToken: Codable, Equatable {
    let tType: TokenType
    let startI: Int
    let endI: Int
    let contents: String
    let degree: Int
    let renderStart: Int
    let renderEnd: Int

    enum CodingKeys: String, CodingKey {
        case tType, startI, endI, contents, degree, renderStart, renderEnd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tType = try container.decode(TokenType.self, forKey: .tType)
        startI = try container.decode(Int.self, forKey: .startI)
        endI = try container.decode(Int.self, forKey: .endI)
        contents = try container.decode(String.self, forKey: .contents)
        degree = try container.decode(Int.self, forKey: .degree)
        renderStart = try container.decodeIfPresent(Int.self, forKey: .renderStart) ?? 0
        renderEnd = try container.decodeIfPresent(Int.self, forKey: .renderEnd) ?? 0
    }

    init(tType: TokenType, startI: Int, endI: Int, contents: String, degree: Int, renderStart: Int = 0, renderEnd: Int = 0) {
        self.tType = tType
        self.startI = startI
        self.endI = endI
        self.contents = contents
        self.degree = degree
        self.renderStart = renderStart
        self.renderEnd = renderEnd
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
