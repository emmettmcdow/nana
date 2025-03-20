//
//  Buttons.swift
//  nana
//
//  Created by Emmett McDow on 3/2/25.
//

import SwiftUI

struct CircularPlusButton: View {
    var action: () -> Void
    var colorScheme: ColorScheme = .light
    var size: CGFloat = 50
    @State var hover = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(colorA(colorScheme: colorScheme).mix(with: .black, by: hover ? 0.1 : 0.0))
                    .frame(width: size, height: size)
                    .shadow(radius: 2)
                    .tint(hover ? .green : .clear)
                
                Image(systemName: "plus")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(colorB(colorScheme: colorScheme))
            }
        }.buttonStyle(PlainButtonStyle())
            .onHover{ _ in
                self.hover.toggle()
            }
            
    }
}

struct SearchButton: View {
    var action: () -> Void
    var colorScheme: ColorScheme = .light
    var size: CGFloat = 50
    @State var shouldPresentSheet = false
    @State var hover = false
    
    @State private var notes: [Note] = [
        Note(id: 0, created: Date(), modified: Date(), relpath: "/foo/bar", content: li1),
        Note(id: 1, created: Date(), modified: Date(), relpath: "/foo/bar2", content: li2),
        Note(id: 2, created: Date(), modified: Date(), relpath: "/foo/bar3", content: li3),
        Note(id: 3, created: Date(), modified: Date(), relpath: "/foo/bar4", content: li3),
        Note(id: 4, created: Date(), modified: Date(), relpath: "/foo/bar5", content: li3),
        Note(id: 5, created: Date(), modified: Date(), relpath: "/foo/bar6", content: li3),
        Note(id: 6, created: Date(), modified: Date(), relpath: "/foo/bar7", content: li3),
    ]
    
    var body: some View {
        Button (action: {action(); shouldPresentSheet.toggle()}){
            ZStack() {
                Circle()
                    .fill(colorA(colorScheme: colorScheme).mix(with: .black, by: hover ? 0.1 : 0.0))

                    .frame(width: size, height: size)
                    .shadow(radius: 2)
                
                Image(systemName: "magnifyingglass")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(colorB(colorScheme: colorScheme))
            }
        }
        .sheet(isPresented: $shouldPresentSheet) {
            FileList(notes: notes)
        }
        .interactiveDismissDisabled(false)
        .buttonStyle(PlainButtonStyle())
        .onHover{ _ in
            self.hover.toggle()
        }
    }
}
