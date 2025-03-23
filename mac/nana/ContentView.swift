//
//  ContentView.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI

import NanaKit

let lightYellow = Color(red: 0.7607843137254902, green: 0.7137254901960784, blue: 0.5843137254901961)
let darkBrown = Color(red:0.14901960784313725, green: 0.1411764705882353, blue: 0.11372549019607843)

func colorA(colorScheme: ColorScheme) -> Color {
    return colorScheme == .light ? darkBrown : lightYellow
}

func colorB(colorScheme: ColorScheme) -> Color {
    return colorScheme == .dark ? darkBrown : lightYellow
}

func colorC(colorScheme: ColorScheme) -> Color {
    return .gray
}


struct ContentView: View {
    @State private var noteId: Int32
    @State private var text: String = ""
    @State private var queriedNotes: [Note] = []
    @Environment(\.colorScheme) var colorScheme
    //@State private var colorScheme: ColorScheme = .light
    
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
                    SearchButton(action: {
                        print("Search Clicked")
                        var ids = Array<Int32>(repeating: 0, count: 1000)
                        let n = nana_search("", &ids, numericCast(ids.count))
                        queriedNotes = []
                        print(n)
                        print(ids)
                        for i in 0...Int(n-1) {
                            let id = ids[i]
                            print("ID \(id)")
                            
                            let create = nana_create_time(id)
                            assert(create > 0, "Failed to get create_time")
                            
                            let mod = nana_mod_time(id)
                            assert(create > 0, "Failed to get mod_time")
                            
                            var content_buf = Array<Int8>(repeating: 0, count: 1000)
                            let sz = nana_read_all(id, &content_buf, numericCast(content_buf.count))
                            assert(sz >= 0, "Failed to read content")
                            let content = String(cString: content_buf, encoding: .utf8) ?? ""
                            
                            queriedNotes.append(Note(id:       id,
                                                     content:  content,
                                                     created:  Date(timeIntervalSince1970: TimeInterval(create)),
                                                     modified: Date(timeIntervalSince1970: TimeInterval(mod))))
                        }
                        
                    }, notes: queriedNotes, colorScheme: colorScheme)
                    CircularPlusButton(action: {
                        print("Add Clicked")
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
        .background(colorB(colorScheme: colorScheme))
    }
}

#Preview("Editor") {
    ContentView()
}
