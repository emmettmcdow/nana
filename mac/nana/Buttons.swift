//
//  Buttons.swift
//  nana
//
//  Created by Emmett McDow on 3/2/25.
//

import SwiftUI

struct CircularPlusButton: View {
    var action: () -> Void
    var size: CGFloat = 50
    @State var hover = false
    
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(palette.foreground.mix(with: .black, by: hover ? 0.1 : 0.0))
                    .frame(width: size, height: size)
                    .shadow(radius: 2)
                    .tint(hover ? .green : .clear)
                
                Image(systemName: "plus")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(palette.background)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover{ _ in
            self.hover.toggle()
        }
        .preferredColorScheme({
            switch preference {
            case .light: .light
            case .dark: .dark
            case .system: nil
            }
        }())
            
    }
}

struct SearchButton: View {
    var onClick: () -> Void
    var size: CGFloat = 50
    @State var hover = false
    
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        
        Button (action: onClick){
            ZStack() {
                Circle()
                    .fill(palette.foreground.mix(with: .black, by: hover ? 0.1 : 0.0))

                    .frame(width: size, height: size)
                    .shadow(radius: 2)
                
                Image(systemName: "magnifyingglass")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(palette.background)
            }
            
        }
        .buttonStyle(PlainButtonStyle())
        .onHover{ _ in
            self.hover.toggle()
        }
        .preferredColorScheme({
            switch preference {
            case .light: .light
            case .dark: .dark
            case .system: nil
            }
        }())
    }
}
