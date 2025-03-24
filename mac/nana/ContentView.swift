//
//  ContentView.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI

import NanaKit

let light = Color(red: 228 / 255, green: 228 / 255, blue: 228 / 255)
let dark = Color(red: 47 / 255, green: 47 / 255, blue: 47 / 255)

func colorA(colorScheme: ColorScheme) -> Color {
    return colorScheme == .light ? dark : light
}

func colorB(colorScheme: ColorScheme) -> Color {
    return colorScheme == .dark ? dark : light
}

func colorC(colorScheme: ColorScheme) -> Color {
    return .gray
}


struct ContentView: View {
    @State private var noteId: Int32
    @State private var text: String = ""
    @State private var queriedNotes: [Note] = []
    @State var shouldPresentSheet = false
    @Environment(\.colorScheme) var colorScheme
    //@State private var colorScheme: ColorScheme = .dark
    init() {
        let newId = nana_create()
        assert(newId > 0, "Failed to create new note")
        noteId = newId
    }
    
    var body: some View {
        ZStack() {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .foregroundColor(colorA(colorScheme: colorScheme))
                .accentColor(colorA(colorScheme: colorScheme))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 0))
                .background(colorB(colorScheme: colorScheme))
                .scrollIndicators(.never)

            HStack() {
                Spacer()
                VStack() {
                    Spacer()
                    SearchButton(onClick: {
                        var ids = Array<Int32>(repeating: 0, count: 100)
                        let n = nana_search("", &ids, numericCast(ids.count), noteId)
                        queriedNotes = []
                        for i in 0...Int(n-1) {
                            let id = ids[i]
                            queriedNotes.append(Note(id: id))
                        }
                        shouldPresentSheet.toggle()
                    }, colorScheme: colorScheme)
                    CircularPlusButton(action: {
                        let res = nana_write_all(noteId, text)
                        assert(res == 0, "Failed to write all")
                        let newId = nana_create()
                        assert(newId > 0, "Failed to create new note")
                        noteId = newId
                        text = ""
                    }, colorScheme: colorScheme)
                }
            }.padding()
        }
        .sheet(isPresented: $shouldPresentSheet) {
            FileList(notes: $queriedNotes, onSelect: {(note: Note) -> Void in
                if (text.count > 0) {
                    // Save the current buffer
                    let res = nana_write_all(noteId, text)
                    assert(res == 0, "Failed to write all")
                }
                
                noteId = note.id
                text = note.content
                shouldPresentSheet.toggle()
            })
        }
        .interactiveDismissDisabled(false)
        .background(colorB(colorScheme: colorScheme))
    }
}

/*
#Preview("Editor") {
    ContentView()
}*/
