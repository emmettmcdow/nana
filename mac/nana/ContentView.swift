//
//  ContentView.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI
import SwiftUIIntrospect

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
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 0, trailing: 0))
                .background(colorB(colorScheme: colorScheme))
                .scrollIndicators(.never)

            HStack() {
                Spacer()
                VStack() {
                    Spacer()
                    SearchButton(colorScheme: colorScheme)
                    CircularPlusButton(action: {
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
