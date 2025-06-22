//
//  Settings.swift
//  nana
//
//  Created by Emmett McDow on 4/18/25.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

import NanaKit

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
    @State private var showFileImporter = false
    @State private var totalFiles = 0
    @State private var completeFiles = 0
    @State private var importError = ""

    var body: some View {
        VStack {
            Form {
                Picker("Color Scheme:", selection: $preference) {
                    ForEach(ColorSchemePreference.allCases) { option in
                        Text(option.description).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            if importError != "" {
                Text("Failed to import files: \(importError)")
                    .lineLimit(nil)
            } else if totalFiles != completeFiles {
                ProgressView(value: Float(completeFiles), total: Float(totalFiles))
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
            } else if totalFiles != 0 {
                Text("Successfully imported \(totalFiles) files")
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
                        guard res >= 0 else {
                            await MainActor.run {
                                importError = "Failed to import " + fileURL + " with error: \(res)"
                                totalFiles = 0
                            }
                            return
                        }
                        await MainActor.run {
                            completeFiles += 1
                        }
                    }
                }
            }
        }
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

// switch result {
// case .success(let dirs):
// case .failure(let error):
//     // handle error
//     print(error)
// }

func importObsidianDir(dir _: URL, completeFiles _: Binding<Int>, totalFiles _: Binding<Int>) {}
