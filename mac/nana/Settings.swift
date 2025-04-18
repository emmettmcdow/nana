//
//  Settings.swift
//  nana
//
//  Created by Emmett McDow on 4/18/25.
//

import Foundation
import SwiftUI

enum AppColorScheme: String, CaseIterable, Identifiable, Codable {
    case light = "Light"
    case dark = "Dark"
    case system = "System"
    
    var id: String { rawValue }
}

func fromSys(sysColor: ColorScheme) -> AppColorScheme {
    return (sysColor == ColorScheme.light) ? .light : .dark
}

let light = Color(red: 228 / 255, green: 228 / 255, blue: 228 / 255)
let dark = Color(red: 47 / 255, green: 47 / 255, blue: 47 / 255)
let gray = Color.gray

enum ColorSchemePreference: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var description: String { rawValue.capitalized }
}

struct Palette {
    var foreground: Color
    var background: Color
    var tertiary:   Color
    
    static func forPreference(_ preference: ColorSchemePreference, colorScheme: ColorScheme) -> Palette {
        switch preference {
        case .light:
            return Palette(foreground: dark, background: light, tertiary: gray)
        case .dark:
            return Palette(foreground: light, background: dark, tertiary: gray)
        case .system:
            return colorScheme == .light ?
                Palette(foreground: dark, background: light, tertiary: gray) :
                Palette(foreground: light, background: dark, tertiary: gray)
        }
    }
}



struct GeneralSettingsView: View {
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system


    var body: some View {
        Form {
            Picker("Color Scheme:", selection: $preference) {
                ForEach(ColorSchemePreference.allCases) { option in
                    Text(option.description).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}
