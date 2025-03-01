//
//  ContentView.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI


let lightYellow = Color(red: 0.7607843137254902, green: 0.7137254901960784, blue: 0.5843137254901961)
let darkBrown = Color(red:0.14901960784313725, green: 0.1411764705882353, blue: 0.11372549019607843)

func colorA(colorScheme: ColorScheme) -> Color {
    return colorScheme == .light ? darkBrown : lightYellow
}

func colorB(colorScheme: ColorScheme) -> Color {
    return colorScheme == .dark ? darkBrown : lightYellow
}

struct CircularPlusButton: View {
    var action: () -> Void
    var colorScheme: ColorScheme = .light
    var size: CGFloat = 50
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(colorA(colorScheme: colorScheme))
                    .frame(width: size, height: size)
                    .shadow(radius: 2)
                
                Image(systemName: "plus")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(colorB(colorScheme: colorScheme))
            }
        }.buttonStyle(PlainButtonStyle())
    }
}

struct SearchButton: View {
    var action: () -> Void
    var colorScheme: ColorScheme = .light
    var size: CGFloat = 50
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(colorA(colorScheme: colorScheme))
                    .frame(width: size, height: size)
                    .shadow(radius: 2)
                
                Image(systemName: "magnifyingglass")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(colorB(colorScheme: colorScheme))
            }
        }.buttonStyle(PlainButtonStyle())
    }
}

struct ContentView: View {
    @State private var text: String = ""
    @Environment(\.colorScheme) var colorScheme
    //@State private var colorScheme: ColorScheme = .light
    
    var body: some View {
        ZStack() {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .foregroundColor(colorA(colorScheme: colorScheme))
                .accentColor(colorA(colorScheme: colorScheme))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(colorB(colorScheme: colorScheme))
            HStack() {
                Spacer()
                VStack() {
                    Spacer()
                    SearchButton(action: {
                        print("Button tapped!")
                    }, colorScheme: colorScheme)
                    CircularPlusButton(action: {
                        print("Button tapped!")
                    }, colorScheme: colorScheme)
                }
            }
        }
        .padding()
        .background(colorB(colorScheme: colorScheme))
    }
}

/*
struct FileList: View {
    @State private var notes: [Note] = [
        Note(created: Date, modified: Date, relpath: "/foo/bar", content: "This is a note #1"),
    ]
    
    var body: some View {
        List(notes) { friend in
        }
    }
}*/

#Preview("Editor") {
    ContentView()
}

#Preview("File List") {
    ContentView()
}
