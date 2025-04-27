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
    @State private var showFileImporter = false
    @State private var totalFiles = 0
    @State private var completeFiles = 0


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
            
            if (totalFiles != completeFiles) {
                ProgressView(value: Float(completeFiles), total: Float(totalFiles))
                    .progressViewStyle(.linear)
                    .padding(.horizontal)
            } else if (totalFiles != 0) {
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
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let dirs):
                    dirs.forEach { dir in
                        // gain access to the directory
                        let gotAccess = dir.startAccessingSecurityScopedResource()
                        if !gotAccess { return }
                        let resourceKeys : [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
                        let enumerator = FileManager.default.enumerator(at: dir,
                                                    includingPropertiesForKeys: resourceKeys,
                                                                       options: [.skipsHiddenFiles], errorHandler: { (url, error) -> Bool in
                                                                                print("directoryEnumerator error at \(url): ", error)
                                                                                return true
                            })!
                        totalFiles = 0
                        for case let fileURL as URL in enumerator {
                            do {
                                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                                if (!resourceValues.isDirectory!) {
                                    totalFiles += 1
                                }
                            } catch {
                                print(error)
                            }

                        }
                        
                        let enumerator2 = FileManager.default.enumerator(at: dir,
                                                    includingPropertiesForKeys: resourceKeys,
                                                                       options: [.skipsHiddenFiles], errorHandler: { (url, error) -> Bool in
                                                                                print("directoryEnumerator error at \(url): ", error)
                                                                                return true
                            })!
                        for case let fileURL as URL in enumerator2 {
                            do {
                                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                                if (!resourceValues.isDirectory!) {
                                    let res = nana_import(fileURL.path, numericCast(fileURL.path.count))
                                    if res <= 0 {
                                        print("Failed to import " + fileURL.path + " with error: \(res)")
                                    }
                                    completeFiles += 1
                                }
                            } catch {
                                print(error)
                            }

                        }

                        // release access
                        dir.stopAccessingSecurityScopedResource()
                    }
                case .failure(let error):
                    // handle error
                    print(error)
                }
            }
        }
    }
}

func importObsidianDir(dir: URL, completeFiles: Binding<Int>, totalFiles: Binding<Int>) {
}
