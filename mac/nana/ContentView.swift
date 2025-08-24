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
    @State private var note: Note
    @State private var queriedNotes: [Note] = []
    @State var searchVisible = false
    @State private var searchTimer: Timer?
    @State private var hover: Bool = false

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    init() {
        let newId = nana_create()
        assert(newId > 0, "Failed to create new note")
        note = Note(id: newId)
    }

    private func search(q: String) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
            var ids = [Int32](repeating: 0, count: MAX_ITEMS)
            let n = min(Int(nana_search(q, &ids, numericCast(ids.count), note.id)), MAX_ITEMS)
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
            Editor(note: $note, palette: palette)

            if searchVisible {
                FileList(notes: $queriedNotes,
                         onSelect: { (selected: Note) in
                             note = selected
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
                            searchVisible.toggle()
                        })
                        .keyboardShortcut("k")
                        CircularPlusButton(action: {
                            let newId = nana_create()
                            assert(newId > 0, "Failed to create new note")
                            note = Note(id: newId)
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

            TextEditor(text: $textObserver.note.content)
                .font(.system(size: fontSize))
                .foregroundColor(palette.foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 0))
                .background(palette.background)
                .scrollIndicators(.never)
                .onAppear {
                    textObserver.note = note
                }
                .onChange(of: note) { _, newValue in
                    textObserver.note = newValue
                }
        }
    }
}

class TextFieldObserver: ObservableObject {
    @Published var note: Note = .init(id: -1)

    private var subscriptions = Set<AnyCancellable>()

    init() {
        $note
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink(receiveValue: { [weak self] n in
                _ = self
                if n.id == -1 {
                    return
                }
                let res = nana_write_all(n.id, n.content)
                assert(res == 0, "Failed to write all")
            })
            .store(in: &subscriptions)
    }
}

#Preview("Editor") {
    ContentView()
}
