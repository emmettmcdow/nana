//
//  Settings.swift
//  nana
//
//  Created by Emmett McDow on 4/18/25.
//

import Foundation
import SwiftUI

#if DISABLE_NANAKIT
    // Previews build without NanaKit; keep the settings UI renderable.
    private func nana_render_font_size() -> Double { 20 }
    private func nana_render_set_font_size(_: Double) {}
#else
    import NanaKit
#endif

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
    var tertiary: Color

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

    func NSbg() -> NSColor {
        return NSColor(background)
    }

    func NSfg() -> NSColor {
        return NSColor(foreground)
    }

    func NStert() -> NSColor {
        return NSColor(tertiary)
    }
}

struct StylePreview: View {
    var sz: Double
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        HStack {
            VStack(alignment: .leading) {
                Text("The quick brown fox jumped over the lazy dog")
                    .font(.system(size: sz))
                Spacer()
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme({
            switch preference {
            case .light: .light
            case .dark: .dark
            case .system: nil
            }
        }())
        .background(palette.background)
        .foregroundStyle(palette.foreground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(radius: 10)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme
    // Font size belongs to Zig, which clamps and persists it. Mirrored into @State only so the
    // stepper has something to bind to; Zig stays the source of truth.
    @State private var fontSize: Double = nana_render_font_size()

    var body: some View {
        Form {
            Section(header: Text("Font and Color")) {
                Picker("Color Scheme:", selection: $preference) {
                    ForEach(ColorSchemePreference.allCases) { option in
                        Text(option.description).tag(option)
                    }
                }
                .pickerStyle(.inline)
                Stepper("Font Size: \(fontSize.formatted())px",
                        value: $fontSize,
                        in: 8 ... 64)
                    .onChange(of: fontSize) { _, size in nana_render_set_font_size(size) }
            }
            Section(header: Text("Preview")) {
                StylePreview(sz: fontSize)
                    .padding()
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 250, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .preferredColorScheme(nil)
    }
}

#Preview("Settings") {
    GeneralSettingsView()
}
