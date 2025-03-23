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
    var onClick: () -> Void
    var colorScheme: ColorScheme = .light
    var size: CGFloat = 50
    @State var hover = false
    
    var body: some View {
        Button (action: onClick){
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
        .buttonStyle(PlainButtonStyle())
        .onHover{ _ in
            self.hover.toggle()
        }
    }
}
