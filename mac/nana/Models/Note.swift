//
//  Note.swift
//  nana
//
//  Created by Emmett McDow on 2/28/25.
//

import Foundation

#if DISABLE_NANAKIT
    // Stub implementations for SwiftUI Previews
    private func nana_create_time(_: UnsafePointer<CChar>) -> Int64 {
        return Int64(Date().timeIntervalSince1970)
    }

    private func nana_mod_time(_: UnsafePointer<CChar>) -> Int64 {
        return Int64(Date().timeIntervalSince1970)
    }

    private func nana_read_all(_: UnsafePointer<CChar>, _ buffer: UnsafeMutablePointer<CChar>?, _ bufferSize: UInt32) -> Int32 {
        let sampleContent =
            """
            Sample note content for preview. Foo bar baz bop bing bang boom yap yip
            zing zang zip soop I pledge allegiance to the united states of america and to the republic
            for which it stands one nation under god indivisibile with liberty and justice for all. the
            quick brown fox jumped over the lazy dog.
            Sample note content for preview. Foo bar baz bop bing bang boom yap yip
            zing zang zip soop I pledge allegiance to the united states of america and to the republic
            for which it stands one nation under god indivisibile with liberty and justice for all. the
            quick brown fox jumped over the lazy dog.
            """
        guard let buffer = buffer else { return -1 }
        let utf8Array = Array(sampleContent.utf8)

        if utf8Array.count >= bufferSize {
            return -1
        }

        for (i, byte) in utf8Array.enumerated() {
            buffer[i] = CChar(bitPattern: byte)
        }
        buffer[utf8Array.count] = 0
        return Int32(utf8Array.count)
    }

    private func nana_write_all_with_time(_: UnsafePointer<CChar>, _: UnsafePointer<CChar>) -> Int64 {
        return Int64(Date().timeIntervalSince1970)
    }

    private func nana_title(_: UnsafePointer<CChar>, _ buf: UnsafeMutablePointer<CChar>?) -> UnsafePointer<CChar>? {
        return UnsafePointer(buf)
    }

    let TITLE_BUF_SZ: Int32 = 64
#else
    import NanaKit
#endif

struct Note: Identifiable, Equatable {
    var id: String  // path
    var created: Date
    var modified: Date
    var content: String
    var title: String
}

// 1MB
let MAX_BUF = 1_000_000
extension Note {
    init(path: String) {
        if path.isEmpty {
            self.id = ""
            created = Date.now
            modified = Date.now
            content = ""
            title = ""
            return
        }

        let create = path.withCString { cString in
            nana_create_time(cString)
        }
        // 0 is valid for lazily-created files that haven't been written yet
        assert(create >= 0, "Failed to get create_time for \(path)")

        let mod = path.withCString { cString in
            nana_mod_time(cString)
        }
        // 0 is valid for lazily-created files that haven't been written yet
        assert(mod >= 0, "Failed to get mod_time for \(path)")

        var bufsize = 10
        var sz: Int32 = -1
        var content_buf = [CChar](repeating: 0, count: bufsize)
        while bufsize < MAX_BUF {
            sz = path.withCString { pathCString in
                content_buf.withUnsafeMutableBufferPointer { buffer in
                    nana_read_all(pathCString, buffer.baseAddress, UInt32(buffer.count))
                }
            }
            if sz >= 0 {
                break
            }
            bufsize *= 10
            content_buf = [CChar](repeating: 0, count: bufsize)
        }
        assert(sz >= 0, "Failed to read content for \(path)")

        var title_buf = [CChar](repeating: 1, count: Int(TITLE_BUF_SZ) + 1)
        title_buf[Int(TITLE_BUF_SZ)] = 0
        _ = path.withCString { pathCString in
            title_buf.withUnsafeMutableBufferPointer { buffer in
                nana_title(pathCString, buffer.baseAddress)
            }
        }

        self.id = path
        created = Date(timeIntervalSince1970: TimeInterval(create))
        modified = Date(timeIntervalSince1970: TimeInterval(mod))
        content = String(cString: content_buf)
        title = String(cString: title_buf)
    }

    static func == (lhs: Note, rhs: Note) -> Bool {
        return lhs.id == rhs.id
    }

    func writeAll() -> Date {
        let res = id.withCString { pathCString in
            content.withCString { contentCString in
                nana_write_all_with_time(pathCString, contentCString)
            }
        }
        assert(res > 0, "Failed to write-all note \(id)")
        return Date(timeIntervalSince1970: TimeInterval(res))
    }

    func modTime() -> Date {
        let new_mod = id.withCString { cString in
            nana_mod_time(cString)
        }
        // 0 is valid for lazily-created files that haven't been written yet
        assert(new_mod >= 0, "Failed to get mod_time for \(id)")
        return Date(timeIntervalSince1970: TimeInterval(new_mod))
    }
}
