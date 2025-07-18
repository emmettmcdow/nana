//
//  Settings.swift
//  nana
//
//  Created by Emmett McDow on 4/18/25.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if DEBUG
    func nana_import(_: UnsafePointer<Int8>, _: Int) -> Int32 {
        return 1 // Success
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
}

struct GeneralSettingsView: View {
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @State var showFileImporter = false
    @State var totalFiles = 0
    @State var skippedFiles = 0
    @State var completeFiles = 0
    @State var importError = ""

    var body: some View {
        TabView {
            Tab("Appearance", systemImage: "paintpalette") {
                VStack {
                    Form {
                        Picker("Color Scheme:", selection: $preference) {
                            ForEach(ColorSchemePreference.allCases) { option in
                                Text(option.description).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }.padding()
            }
            Tab("Data", systemImage: "document") {
                VStack {
                    if importError != "" {
                        Text("Failed to import files:")
                        ScrollView {
                            Text(importError)
                                .font(.system(.body, design: .monospaced))
                                .padding()
                        }
                        .frame(maxHeight: 200)
                    } else if totalFiles != (completeFiles + skippedFiles) {
                        Text("Importing \(totalFiles) files...")
                        ProgressView(value: Float(completeFiles), total: Float(totalFiles))
                            .progressViewStyle(.linear)
                            .padding(.horizontal)
                    } else if totalFiles != 0 {
                        Text("Successfully imported \(completeFiles) files")
                        if skippedFiles != 0 {
                            Text("Skipped importing \(completeFiles) files")
                        }
                    }

                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import Obsidian Vault", systemImage: "doc.circle")
                    }
                    .fileImporter(
                        isPresented: $showFileImporter,
                        allowedContentTypes: [.directory],
                        allowsMultipleSelection: false
                    ) { result in
                        Task.detached(priority: .userInitiated) {
                            let gottenResult = try result.get()
                            guard let dirURL = gottenResult.first else {
                                await MainActor.run {
                                    importError = "No directory selected"
                                }
                                return
                            }
                            await MainActor.run {
                                totalFiles = 0
                            }
                            guard dirURL.startAccessingSecurityScopedResource() else {
                                await MainActor.run {
                                    importError = "Failed to start accessing security-scoped resource"
                                    totalFiles = 0
                                }
                                return
                            }
                            defer { dirURL.stopAccessingSecurityScopedResource() }

                            let allFiles = filesInDir(dirURL: dirURL)

                            await MainActor.run {
                                totalFiles = allFiles.count
                            }
                            for fileURL in allFiles {
                                let res = await MainActor.run {
                                    fileURL.withCString { cString in
                                        nana_import(cString, numericCast(fileURL.utf8.count))
                                    }
                                }
                                if res <= 0 {
                                    if res != -13 {
                                        await MainActor.run {
                                            importError = "Failed to import " + fileURL + " with error: \(res)"
                                            totalFiles = 0
                                        }
                                        return
                                    }
                                    await MainActor.run {
                                        skippedFiles += 1
                                    }
                                }
                                await MainActor.run {
                                    completeFiles += 1
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func filesInDir(dirURL: URL) -> [String] {
    var files: [String] = []
    let resourceKeys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey, .pathKey]
    let fileNumberEnumerator = FileManager.default.enumerator(at: dirURL,
                                                              includingPropertiesForKeys: resourceKeys,
                                                              options: [.skipsHiddenFiles],
                                                              errorHandler: { url, error -> Bool in
                                                                  print("directoryEnumerator error at \(url): ", error)
                                                                  return true
                                                              })!
    for case let fileURL as URL in fileNumberEnumerator {
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            if !resourceValues.isDirectory! {
                if let path = resourceValues.path {
                    files.append(path)
                }
            }
        } catch {
            print(error)
        }
    }
    return files
}

#Preview("Settings") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 0,
        skippedFiles: 0,
        completeFiles: 0,
        importError: ""
    )
}

#Preview("Settings Import 50%") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 10,
        skippedFiles: 0,
        completeFiles: 5,
        importError: ""
    )
}

#Preview("Settings Import Complete") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 10,
        skippedFiles: 0,
        completeFiles: 10,
        importError: ""
    )
}

#Preview("Settings Import Complete With Skip") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 10,
        skippedFiles: 1,
        completeFiles: 9,
        importError: ""
    )
}

#Preview("Settings Import Failed") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 10,
        skippedFiles: 0,
        completeFiles: 9,
        importError: "Something went wrong while importing: bufferoverflow, stackoverflow, uh oh big oops OH NO everything is broken we got HACKED."
    )
}
