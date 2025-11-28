//
//  Settings.swift
//  nana
//
//  Created by Emmett McDow on 4/18/25.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if DISABLE_NANAKIT
    // Returns empty double-null-terminated string (no files to import)
    private func nana_doctor(_: UnsafePointer<CChar>) -> UnsafePointer<CChar>? {
        return UnsafePointer(strdup("\0")!)
    }

    private func nana_doctor_finish() {}

    private func nana_init(_: UnsafePointer<CChar>) -> Int32 {
        return 0 // Success
    }

    private func nana_deinit() -> Int32 {
        return 0 // Success
    }
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

struct GeneralSettingsView: View {
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @AppStorage("fontSize") private var fontSize: Double = 14

    @State var showFileImporter = false
    @State var files: [ImportItem] = []
    @State var action: String = ""

    func onProgress(files: [ImportItem]) {
        self.files = files
    }

    var body: some View {
        HStack {
            TabView {
                Tab("Appearance", systemImage: "paintpalette") {
                    // Section(header: Text("Appearance")) {
                    Picker("Color Scheme:", selection: $preference) {
                        ForEach(ColorSchemePreference.allCases) { option in
                            Text(option.description).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    HStack {
                        Stepper("Font Size: \(fontSize.formatted())px", value: $fontSize, in: 1 ... 64)
                    }
                    Text("Preview:")
                    Text("The quick brown fox jumped over the lazy dog")
                        .font(.system(size: fontSize))
                }
                Tab("Shortcuts", systemImage: "keyboard") {
                    List {
                        Section(header: Text("Control")) {
                            HStack {
                                Text("New Note:")
                                Spacer()
                                Text("⌘a").bold().monospaced()
                            }
                            HStack {
                                Text("Search:")
                                Spacer()
                                Text("⌘k").bold().monospaced()
                            }
                            HStack {
                                Text("Exit Search:")
                                Spacer()
                                Text("esc").bold().monospaced()
                            }
                        }
                        Section(header: Text("Display")) {
                            HStack {
                                Text("Increase Font Size:")
                                Spacer()
                                Text("⌘+").bold().monospaced()
                            }
                            HStack {
                                Text("Decrease Font Size:")
                                Spacer()
                                Text("⌘-").bold().monospaced()
                            }
                        }
                    }
                }
                Tab("Data", systemImage: "document") {
                    VStack {
                        Button {
                            action = "import"
                            showFileImporter = true
                        } label: {
                            Label("Import Obsidian Vault", systemImage: "square.and.arrow.down")
                        }
                        .fileImporter(
                            isPresented: $showFileImporter,
                            allowedContentTypes: [.directory],
                            allowsMultipleSelection: false
                        ) { result in
                            Task {
                                try await import_from_dir(result: result, onProgress: onProgress)
                            }
                        }
                        Button {
                            action = "doctor"
                            Task {
                                await import_from_doctor(onProgress: onProgress)
                            }
                        } label: {
                            Label("Fix problems with data", systemImage: "stethoscope")
                        }
                        Spacer()
                        Progress(action: action,
                                 files: files)
                    }
                    .padding()
                }
            }.frame(minWidth: 250, maxWidth: .infinity, minHeight: 250, maxHeight: .infinity)
        }
    }
}

#Preview("Settings") {
    GeneralSettingsView(
        showFileImporter: false,
        files: [],
        action: ""
    )
}

#Preview("Settings Import 50%") {
    GeneralSettingsView(
        showFileImporter: false,
        files: [
            ImportItem(filename: "note1.md", message: "", status: .success),
            ImportItem(filename: "note2.md", message: "", status: .success),
            ImportItem(filename: "note4.md", message: "", status: .queued),
            ImportItem(filename: "note5.md", message: "", status: .queued),
        ],
        action: "import"
    )
}

#Preview("Settings Import Complete") {
    GeneralSettingsView(
        showFileImporter: false,
        files: [
            ImportItem(filename: "note1.md", message: "", status: .success),
            ImportItem(filename: "note2.md", message: "Skippity", status: .skip),
            ImportItem(filename: "note3.md", message: "Faility", status: .fail),
        ],
        action: "doctor"
    )
}
