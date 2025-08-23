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

    func nana_write_all(_: Int32, _: String) -> Int32 {
        return 0 // Success
    }
#else
    import NanaKit
#endif

let MAX_ITEMS = 100

struct ContentView: View {
    @State private var noteId: Int32
    @State private var text: String = ""
    @State private var queriedNotes: [Note] = []
    @State var searchVisible = false
    @State private var searchTimer: Timer?
    @State private var hover: Bool = false

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    init() {
        let newId = nana_create()
        assert(newId > 0, "Failed to create new note")
        noteId = newId
        noteId = 1
    }

    private func search(q: String) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            var ids = [Int32](repeating: 0, count: MAX_ITEMS)
            let n = min(Int(nana_search(q, &ids, numericCast(ids.count), noteId)), MAX_ITEMS)
            if n < 0 {
                print("Some error occurred while searching: ", n)
                return
            }
            queriedNotes = []
            if n > 0 {
                // I have no idea why the docs say its far-end exclusive. It's not. Am i stupid?
                for i in 0 ... (n - 1) {
                    let id = ids[i]
                    queriedNotes.append(Note(id: id))
                }
            }
        }
    }

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)

        ZStack {
            Editor(text: $text, noteID: $noteId, palette: palette)

            if searchVisible {
                FileList(notes: $queriedNotes,
                         onSelect: { (note: Note) in
                             noteId = note.id
                             text = note.content
                             searchVisible.toggle()
                         }, onChange: { (q: String) in
                             search(q: q)
                         }, closeList: { () in
                             searchVisible.toggle()
                         })
            } else {
                HStack {
                    Spacer()
                    VStack {
                        Spacer()
                        SearchButton(onClick: {
                            search(q: "")
                            searchVisible.toggle()
                        })
                        CircularPlusButton(action: {
                            let newId = nana_create()
                            assert(newId > 0, "Failed to create new note")
                            noteId = newId
                            text = ""
                        })
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
    @Binding var text: String
    @Binding var noteID: Int32

    let palette: Palette
    @StateObject private var textObserver = TextFieldObserver()

    @AppStorage("fontSize") private var fontSize: Double = 14

    var body: some View {
        ZStack {
            Group {
                Button("") { fontSize = min(fontSize + 1, 64) }.keyboardShortcut("+")
                Button("") { fontSize = max(fontSize - 1, 1) }.keyboardShortcut("-")
            }
            .opacity(0)
            .hidden()

            TextEditor(text: $text)
                .font(.system(size: fontSize))
                .foregroundColor(palette.foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 0))
                .background(palette.background)
                .scrollIndicators(.never)
                .onAppear {
                    textObserver.text = text
                    textObserver.noteID = noteID
                }
                .onChange(of: text) { newValue in
                    textObserver.text = newValue
                }
                .onChange(of: noteID) { newValue in
                    textObserver.noteID = newValue
                }
        }
    }
}

class TextFieldObserver: ObservableObject {
    @Published var text = ""
    @Published var noteID: Int32 = -1

    private var subscriptions = Set<AnyCancellable>()

    init() {
        $text
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink(receiveValue: { [weak self] t in
                guard let self = self else { return }
                let res = nana_write_all(self.noteID, t)
                assert(res == 0, "Failed to write all")
            })
    }
}

#Preview("Editor") {
    ContentView()
}
