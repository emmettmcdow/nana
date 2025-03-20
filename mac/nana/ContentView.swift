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
                    SearchButton(action: {print("Search Clicked")}, colorScheme: colorScheme)
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
