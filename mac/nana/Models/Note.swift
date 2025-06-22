//
//  Note.swift
//  nana
//
//  Created by Emmett McDow on 2/28/25.
//

import Foundation

#if DEBUG
// Stub implementations for SwiftUI Previews
func nana_create_time(_ id: Int32) -> Int64 {
    return Int64(Date().timeIntervalSince1970)
}

func nana_mod_time(_ id: Int32) -> Int64 {
    return Int64(Date().timeIntervalSince1970)
}

func nana_read_all(_ id: Int32, _ buffer: inout [Int8], _ bufferSize: Int) -> Int32 {
    let sampleContent = "Sample note content for preview"
    let utf8Array = Array(sampleContent.utf8.map { Int8(bitPattern: $0) }) + [0]
    let copyCount = min(utf8Array.count, bufferSize)
    buffer.replaceSubrange(0..<copyCount, with: utf8Array.prefix(copyCount))
    return Int32(copyCount - 1) // Don't count null terminator
}
#else
import NanaKit
#endif

struct Note: Identifiable {
    var id: Int32
    var content: String
    var created: Date
    var modified: Date
}
// 1MB
let MAX_BUF = 1_000_000
extension Note {
    init(id: Int32) {
        let create = nana_create_time(id)
        assert(create > 0, "Failed to get create_time")
        
        let mod = nana_mod_time(id)
        assert(create > 0, "Failed to get mod_time")
        
        var bufsize = 10
        var sz: Int32 = -1
        var content_buf = Array<Int8>(repeating: 0, count: bufsize)
        while (bufsize < MAX_BUF) {
            sz = nana_read_all(id, &content_buf, numericCast(content_buf.count))
            if (sz >= 0) {
                break
            }
            bufsize *= 10
            content_buf = Array<Int8>(repeating: 0, count: bufsize)
        }
        assert(sz >= 0, "Failed to read content")
        
        self.id = id
        self.created = Date(timeIntervalSince1970: TimeInterval(create))
        self.modified = Date(timeIntervalSince1970: TimeInterval(mod))
        self.content = String(cString: content_buf, encoding: .utf8) ?? ""
    }
}
