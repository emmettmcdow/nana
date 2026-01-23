//
//  ContentView.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import Combine
import SwiftUI

#if DISABLE_NANAKIT

    let N_SEARCH_HIGHLIGHTS: Int32 = 5
    let PATH_MAX: Int32 = 1024

    struct CSearchResult {
        var path: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   // ... 924 more for PATH_MAX=1024
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) = (
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                   )
        var start_i: UInt32 = 0
        var end_i: UInt32 = 0
        var similarity: Float = 0.5
    }

    struct CSearchDetail {
        var content: UnsafeMutablePointer<CChar>?
        var highlights: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    // Stub implementations for SwiftUI Previews
    private func nana_create(_ outbuf: UnsafeMutablePointer<CChar>?, _ outbuf_len: UInt32) -> Int32 {
        let path = "preview-note-\(Int.random(in: 1...1000)).md"
        guard let outbuf = outbuf else { return -1 }
        for (i, char) in path.utf8.enumerated() {
            if i >= outbuf_len - 1 { break }
            outbuf[i] = CChar(bitPattern: char)
        }
        outbuf[min(path.utf8.count, Int(outbuf_len) - 1)] = 0
        return Int32(path.utf8.count)
    }

    private func nana_search(_: UnsafePointer<CChar>, _ results: UnsafeMutablePointer<CSearchResult>?, _ maxCount: UInt32) -> Int32 {
        // Return some sample paths for preview
        let samplePaths = ["note1.md", "note2.md", "note3.md"]
        let returnCount = min(samplePaths.count, Int(maxCount))
        for i in 0 ..< returnCount {
            var result = CSearchResult()
            for (j, char) in samplePaths[i].utf8.enumerated() {
                withUnsafeMutableBytes(of: &result.path) { ptr in
                    ptr[j] = char
                }
            }
            result.start_i = 0
            result.end_i = 50
            result.similarity = 0.8
            results?[i] = result
        }
        return Int32(returnCount)
    }

    private func nana_index(_ outbuf: UnsafeMutablePointer<CChar>?, _ sz: UInt32, _: UnsafePointer<CChar>?) -> Int32 {
        // Return sample double-null-terminated paths
        let samplePaths = ["note1.md", "note2.md", "note3.md"]
        guard let outbuf = outbuf else { return 0 }
        var pos = 0
        for path in samplePaths {
            for char in path.utf8 {
                if pos >= sz - 2 { break }
                outbuf[pos] = CChar(bitPattern: char)
                pos += 1
            }
            outbuf[pos] = 0
            pos += 1
        }
        outbuf[pos] = 0
        return Int32(samplePaths.count)
    }

    private func nana_search_detail(_: UnsafePointer<CChar>,
                                    _: UInt32,
                                    _: UInt32,
                                    _: UnsafePointer<CChar>,
                                    _: UnsafeMutablePointer<CSearchDetail>?,
                                    _: Bool) -> Int32
    {
        return 0
    }

#else
    import NanaKit
#endif

struct SearchResult: Identifiable, Equatable {
    var note: Note
    var preview: String
    var highlights: [Int] = Array(repeating: 0, count: Int(N_SEARCH_HIGHLIGHTS) * 2)
    var similarity: Float = 0.0
    let id = UUID()
    static func == (lhs: SearchResult, rhs: SearchResult) -> Bool {
        lhs.id == rhs.id
    }
}

let MAX_ITEMS = 100
let INDEX_BUF_SIZE = 256 * 1024  // 256KB for double-null-terminated paths

class NotesManager: ObservableObject {
    @AppStorage("skipHighlights") private var skipHighlights: Bool = false
    @Published var currentNote: Note
    @Published var queriedNotes: [SearchResult] = []
    @Published var searchVisible = false

    private var cancellables = Set<AnyCancellable>()
    private var modified: Date = .now
    private var writing: Bool = false

    init() {
        var pathBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let pathLen = pathBuf.withUnsafeMutableBufferPointer { buffer in
            nana_create(buffer.baseAddress, UInt32(buffer.count))
        }
        assert(pathLen > 0, "Failed to create new note")
        let path = String(cString: pathBuf)
        currentNote = Note(path: path)
        modified = currentNote.modified

        // Auto-save when content changes
        $currentNote
            .map(\.content)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.global(qos: .utility))
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.saveCurrentNote()
            }
            .store(in: &cancellables)
    }

    private func saveCurrentNote() {
        guard !currentNote.id.isEmpty else { return }
        modified = currentNote.writeAll()
    }

    func createNewNote() {
        var pathBuf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let pathLen = pathBuf.withUnsafeMutableBufferPointer { buffer in
            nana_create(buffer.baseAddress, UInt32(buffer.count))
        }
        assert(pathLen > 0, "Failed to create new note")
        let path = String(cString: pathBuf)
        currentNote = Note(path: path)
    }

    func search(query: String) {
        queriedNotes = []
        var n = 0
        if query.isEmpty {
            // Use nana_index for listing notes
            var outbuf = [CChar](repeating: 0, count: INDEX_BUF_SIZE)
            n = outbuf.withUnsafeMutableBufferPointer { buffer in
                currentNote.id.withCString { ignorePath in
                    Int(nana_index(buffer.baseAddress, UInt32(buffer.count), ignorePath))
                }
            }
            if n < 0 {
                print("Some error occurred while indexing: ", n)
                return
            }
            // Parse double-null-terminated paths
            let paths = parseDoubleNullTerminatedPaths(outbuf)
            for path in paths {
                let note = Note(path: path)
                let preview = note.content
                queriedNotes.append(SearchResult(note: note, preview: preview))
            }
        } else {
            var results = [CSearchResult](repeating: CSearchResult(), count: MAX_ITEMS)
            n = results.withUnsafeMutableBufferPointer { buffer in
                query.withCString { queryCString in
                    min(Int(nana_search(queryCString, buffer.baseAddress, UInt32(MAX_ITEMS))), MAX_ITEMS)
                }
            }
            if n < 0 {
                print("Some error occurred while searching: ", n)
                return
            }
            for i in 0 ..< n {
                let result = results[i]
                let path = withUnsafePointer(to: result.path) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(PATH_MAX)) { charPtr in
                        String(cString: charPtr)
                    }
                }
                let note = Note(path: path)

                let bufsize = Int((result.end_i - result.start_i) + 1)

                let charPointer = UnsafeMutablePointer<CChar>.allocate(capacity: bufsize + 1)
                charPointer.initialize(repeating: 0x01, count: bufsize)
                charPointer[bufsize] = 0
                var tmp_search_detail = CSearchDetail(content: charPointer,
                                                      highlights: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
                let detailResult = path.withCString { pathCString in
                    query.withCString { queryCString in
                        nana_search_detail(pathCString,
                                           result.start_i,
                                           result.end_i,
                                           queryCString,
                                           &tmp_search_detail,
                                           skipHighlights)
                    }
                }
                guard detailResult == 0 else {
                    charPointer.deallocate()
                    continue
                }
                let highlights = Mirror(reflecting: tmp_search_detail.highlights).children.map {
                    Int($0.value as! UInt32)
                } as! [Int]
                let preview: String
                if let content = tmp_search_detail.content {
                    preview = String(cString: content)
                } else {
                    preview = ""
                }
                queriedNotes.append(SearchResult(note: note,
                                                 preview: preview,
                                                 highlights: highlights,
                                                 similarity: result.similarity))
            }
        }
    }
}

/// Parse a double-null-terminated buffer into an array of paths
func parseDoubleNullTerminatedPaths(_ buffer: [CChar]) -> [String] {
    var paths: [String] = []
    var start = 0
    for i in 0 ..< buffer.count {
        if buffer[i] == 0 {
            if i == start {
                // Double null - end of list
                break
            }
            let pathData = buffer[start ..< i]
            if let path = String(bytes: pathData.map { UInt8(bitPattern: $0) }, encoding: .utf8) {
                paths.append(path)
            }
            start = i + 1
        }
    }
    return paths
}

struct ContentView: View {
    @EnvironmentObject private var notesManager: NotesManager
    @State private var searchTimer: Timer?
    @State private var hover: Bool = false
    @State private var showingToast = false
    @State private var toastMessage = ""

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("fontSize") private var fontSize: Double = 14

    private func search(q: String) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            notesManager.search(query: q)
        }
    }

    func toast(msg: String) {
        withAnimation {
            showingToast = true
        }
        toastMessage = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation {
                showingToast = false
            }
        }
    }

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)

        ZStack {
            MarkdownEditor(
                text: $notesManager.currentNote.content,
                palette: palette,
                font: NSFont.systemFont(ofSize: fontSize)
            ).mask(
                LinearGradient(gradient: Gradient(stops: [
                    .init(color: .clear, location: 0), // Top fade
                    .init(color: .black, location: 0.05), // Start opaque
                    .init(color: .black, location: 0.95), // End opaque
                    .init(color: .clear, location: 1), // Bottom fade
                ]), startPoint: .top, endPoint: .bottom)
            )
            FileList(visible: $notesManager.searchVisible, results: $notesManager.queriedNotes,
                     onSelect: { (selected: SearchResult) in
                         notesManager.currentNote = selected.note
                         withAnimation(.spring) {
                             notesManager.searchVisible.toggle()
                         }
                     }, onChange: { (q: String) in
                         search(q: q)
                     }, closeList: { () in
                         withAnimation(.spring) {
                             notesManager.searchVisible.toggle()
                         }
                     })
            HStack {
                Spacer()
                VStack {
                    Spacer()
                    SearchButton(onClick: {
                        withAnimation(.spring) {
                            notesManager.searchVisible.toggle()
                        }
                    })
                    .disabled(notesManager.searchVisible)
                    .keyboardShortcut("s")
                    CircularPlusButton(action: {
                        notesManager.createNewNote()
                        toast(msg: "Created new note")
                    })
                    .disabled(notesManager.searchVisible)
                }
            }.padding()
            ToastView(showingToast: $showingToast, message: $toastMessage)
        }
        .background(palette.background)
        .preferredColorScheme({
            switch preference {
            case .light: .light
            case .dark: .dark
            case .system: nil
            }
        }())
    }
}

struct ToastView: View {
    @Binding var showingToast: Bool
    @Binding var message: String

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        HStack {
            VStack {
                Spacer()
                if showingToast {
                    Text(message)
                        .padding()
                        .background(palette.background.opacity(0.7))
                        .foregroundColor(palette.foreground.opacity(0.7))
                        .italic()
                        .cornerRadius(10)
                        .shadow(radius: 10)
                        .padding()
                        .zIndex(100)
                        .transition(.opacity)
                        .animation(.spring, value: showingToast)
                }
            }
            Spacer()
        }
    }
}

#Preview("Editor") {
    ContentView()
        .environmentObject(NotesManager())
}
