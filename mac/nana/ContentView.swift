//
//  ContentView.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI

#if DEBUG
// Stub implementations for SwiftUI Previews
func nana_create() -> Int32 {
    return Int32.random(in: 1...1000)
}

func nana_search(_ query: String, _ ids: inout [Int32], _ maxCount: Int, _ currentNoteId: Int32) -> Int32 {
    // Return some sample note IDs for preview
    let sampleIds: [Int32] = [1, 2, 3, 4, 5]
    let returnCount = min(sampleIds.count, maxCount)
    for i in 0..<returnCount {
        ids[i] = sampleIds[i]
    }
    return Int32(returnCount)
}

func nana_write_all(_ id: Int32, _ content: String) -> Int32 {
    return 0 // Success
}
#else
import NanaKit
#endif


struct ContentView: View {
    @State private var noteId: Int32
    @State private var text: String = ""
    @State private var queriedNotes: [Note] = []
    @State var searchVisible = false
    
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme


    init() {
        let newId = nana_create()
        assert(newId > 0, "Failed to create new note")
        noteId = newId
        noteId = 1
    }
    
    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        
        ZStack() {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .foregroundColor(palette.foreground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 0))
                .background(palette.background)
                .scrollIndicators(.never)

            HStack() {
                Spacer()
                VStack() {
                    Spacer()
                    SearchButton(onClick: {
                        var ids = Array<Int32>(repeating: 0, count: 100)
                        let n = nana_search("", &ids, numericCast(ids.count), noteId)
                        if (n < 0 ) {
                            print("Some error occurred while searching: ", n)
                            return
                        }
                        queriedNotes = []
                        if (n > 0) {
                            // I have no idea why the docs say its far-end exclusive. It's not. Am i stupid?
                            for i in 0...Int(n-1) {
                                let id = ids[i]
                                queriedNotes.append(Note(id: id))
                            }
                        }
                        searchVisible.toggle()
                    })
                    CircularPlusButton(action: {
                        let res = nana_write_all(noteId, text)
                        assert(res == 0, "Failed to write all")
                        let newId = nana_create()
                        assert(newId > 0, "Failed to create new note")
                        noteId = newId
                        text = ""
                    })
                }
            }.padding()
            if searchVisible {
                FileList(notes: $queriedNotes,
                         onSelect: {(note: Note) -> Void in
                    if (text.count > 0) {
                        // Save the current buffer
                        let res = nana_write_all(noteId, text)
                        assert(res == 0, "Failed to write all")
                    }
                    
                    noteId = note.id
                    text = note.content
                    searchVisible.toggle()
                }, onChange: {(q: String) -> Void in
                    print(q)
                    /*
                    var ids = Array<Int32>(repeating: 0, count: 100)
                    let n = nana_search(q, &ids, numericCast(ids.count), noteId)
                    queriedNotes = []
                    if (n > 0) {
                        for i in 0...Int(n-1) {
                            let id = ids[i]
                            queriedNotes.append(Note(id: id))
                        }
                    }*/
                }, closeList: {() -> Void in
                    searchVisible.toggle()
                })
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


#Preview("Editor") {
    ContentView()
}
