//
//  ContentView.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import Combine
import SwiftUI

#if DISABLE_NANAKIT

    struct CSearchResult {
        var id: UInt32
        var start_i: UInt32
        var end_i: UInt32
    }

    // Stub implementations for SwiftUI Previews
    private func nana_create() -> Int32 {
        return Int32.random(in: 1 ... 1000)
    }

    private func nana_search(_: String, _ ids: inout [CSearchResult], _ maxCount: Int) -> Int32 {
        // Return some sample note IDs for preview
        let sampleIds: [Int32] = [1, 2, 3, 4, 5]
        let returnCount = min(sampleIds.count, maxCount)
        for i in 0 ..< returnCount {
            ids[i] = CSearchResult(id: UInt32(sampleIds[i]), start_i: 0, end_i: 5)
        }
        return Int32(returnCount)
    }

    private func nana_index(_ ids: inout [Int32], _ maxCount: Int, _: Int32) -> Int32 {
        // Return some sample note IDs for preview
        let sampleIds: [Int32] = [1, 2, 3, 4, 5]
        let returnCount = min(sampleIds.count, maxCount)
        for i in 0 ..< returnCount {
            ids[i] = sampleIds[i]
        }
        return Int32(returnCount)
    }

#else
    import NanaKit
#endif

struct SearchResult: Identifiable {
    var note: Note
    var preview: String
    let id = UUID()
}

let MAX_ITEMS = 100

class NotesManager: ObservableObject {
    @Published var currentNote: Note
    @Published var queriedNotes: [SearchResult] = []
    @Published var searchVisible = false

    private var cancellables = Set<AnyCancellable>()
    private var modified: Date = .now
    private var writing: Bool = false

    init() {
        let newId = nana_create()
        assert(newId > 0, "Failed to create new note")
        currentNote = Note(id: newId)
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
        guard currentNote.id != -1 else { return }
        modified = currentNote.writeAll()
    }

    func createNewNote() {
        let newId = nana_create()
        assert(newId > 0, "Failed to create new note")
        currentNote = Note(id: newId)
    }

    func search(query: String) {
        queriedNotes = []
        var n = 0
        if query.isEmpty {
            var ids = [Int32](repeating: 0, count: MAX_ITEMS)
            n = min(Int(nana_index(&ids, numericCast(ids.count), currentNote.id)), MAX_ITEMS)
            if n < 0 {
                print("Some error occurred while searching: ", n)
                return
            }
            for i in 0 ..< n {
                let result = ids[i]
                let note = Note(id: Int32(result))
                let preview = note.content
                queriedNotes.append(SearchResult(note: note, preview: preview))
            }
        } else {
            var results = [CSearchResult](repeating: CSearchResult(id: 0, start_i: 0, end_i: 0),
                                          count: MAX_ITEMS)
            n = min(Int(nana_search(query, &results, numericCast(MAX_ITEMS))), MAX_ITEMS)
            if n < 0 {
                print("Some error occurred while searching: ", n)
                return
            }
            for i in 0 ..< n {
                let result = results[i]
                let note = Note(id: Int32(result.id))
                let content = note.content
                let startIndex = content.index(content.startIndex, offsetBy: Int(result.start_i), limitedBy: content.endIndex) ?? content.startIndex
                let endIndex = content.index(content.startIndex, offsetBy: Int(result.end_i), limitedBy: content.endIndex) ?? content.endIndex
                let preview = String(content[startIndex ..< endIndex])
                queriedNotes.append(SearchResult(note: note, preview: preview))
            }
        }
    }
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
            if notesManager.searchVisible {
                FileList(results: $notesManager.queriedNotes,
                         onSelect: { (selected: SearchResult) in
                             notesManager.currentNote = selected.note
                             notesManager.searchVisible.toggle()
                         }, onChange: { (q: String) in
                             search(q: q)
                         }, closeList: { () in
                             notesManager.searchVisible.toggle()
                         })
            } else {
                HStack {
                    Spacer()
                    VStack {
                        Spacer()
                        SearchButton(onClick: {
                            notesManager.searchVisible.toggle()
                        })
                        .keyboardShortcut("s")
                        CircularPlusButton(action: {
                            notesManager.createNewNote()
                            toast(msg: "Created new note")
                        })
                    }
                }.padding()
            }
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
