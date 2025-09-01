//
//  ContentView.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import Combine
import SwiftUI

#if DISABLE_NANAKIT
    // Stub implementations for SwiftUI Previews
    func nana_create() -> Int32 {
        return Int32.random(in: 1 ... 1000)
    }

    func nana_search(_: String, _ ids: inout [Int32], _ maxCount: Int, _: Int32) -> Int32 {
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

let MAX_ITEMS = 100

class NotesManager: ObservableObject {
    @Published var currentNote: Note
    @Published var queriedNotes: [Note] = []
    @Published var searchVisible = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        let newId = nana_create()
        assert(newId > 0, "Failed to create new note")
        currentNote = Note(id: newId)

        // Background refresh timer
        Timer.publish(every: 5.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkForStaleNote()
            }
            .store(in: &cancellables)

        // Auto-save when content changes
        $currentNote
            .map(\.content)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.saveCurrentNote()
            }
            .store(in: &cancellables)
    }

    private func checkForStaleNote() {
        if currentNote.isStale() {
            currentNote = Note(id: currentNote.id)
        }
    }

    private func saveCurrentNote() {
        guard currentNote.id != -1 else { return }
        var mutableNote = currentNote
        mutableNote.writeAll()
        currentNote = mutableNote
    }

    func createNewNote() {
        let newId = nana_create()
        assert(newId > 0, "Failed to create new note")
        currentNote = Note(id: newId)
    }

    func search(query: String) {
        queriedNotes = []
        var ids = [Int32](repeating: 0, count: MAX_ITEMS)
        let n = min(Int(nana_search(query, &ids, numericCast(ids.count), currentNote.id)), MAX_ITEMS)
        if n < 0 {
            print("Some error occurred while searching: ", n)
            return
        }
        if n > 0 {
            for i in 0 ... (n - 1) {
                let id = ids[i]
                queriedNotes.append(Note(id: id))
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var notesManager = NotesManager()
    @State private var searchTimer: Timer?
    @State private var hover: Bool = false

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    private func search(q: String) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            notesManager.search(query: q)
        }
    }

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)

        ZStack {
            Editor(note: $notesManager.currentNote, palette: palette)

            if notesManager.searchVisible {
                FileList(notes: $notesManager.queriedNotes,
                         onSelect: { (selected: Note) in
                             notesManager.currentNote = selected
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
                        .keyboardShortcut("k")
                        CircularPlusButton(action: {
                            notesManager.createNewNote()
                        })
                        .keyboardShortcut("a")
                    }
                }.padding()
            }
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

struct Editor: View {
    @Binding var note: Note
    let palette: Palette
    @AppStorage("fontSize") private var fontSize: Double = 14

    var body: some View {
        ZStack {
            Group {
                Button("") { fontSize = min(fontSize + 1, 64) }.keyboardShortcut("+")
                Button("") { fontSize = max(fontSize - 1, 1) }.keyboardShortcut("-")
            }
            .opacity(0)
            .hidden()

            TextEditor(text: $note.content)
                .font(.system(size: fontSize))
                .foregroundColor(palette.foreground)
                .accentColor(palette.foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 0))
                .background(palette.background)
                .scrollIndicators(.never)
        }
    }
}

#Preview("Editor") {
    ContentView()
}
