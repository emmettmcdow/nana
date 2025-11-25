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
    @State var totalFiles = 0
    @State var skippedFiles: [ImportResult] = []
    @State var erroredFiles: [ImportResult] = []
    @State var completeFiles: [ImportResult] = []
    @State var action: String = ""

    func import_from_dir(result: Result<[URL], any Error>) async throws {
        let gottenResult = try result.get()
        guard let dirURL = gottenResult.first else {
            await MainActor.run {
                erroredFiles = [ImportResult(filename: "Directory", message: "No directory selected")]
            }
            return
        }
        await MainActor.run {
            totalFiles = 0
        }
        guard dirURL.startAccessingSecurityScopedResource() else {
            await MainActor.run {
                erroredFiles = [ImportResult(filename: "Directory", message: "Failed to start accessing security-scoped resource")]
                totalFiles = 0
            }
            return
        }
        defer { dirURL.stopAccessingSecurityScopedResource() }

        let allFiles = filesInDir(dirURL: dirURL)

        await MainActor.run {
            totalFiles = allFiles.count
        }
        await importFiles(
            allFiles,
            copy: false,
            addExt: false,
            onProgress: { complete, skipped, errored in
                self.completeFiles = complete
                self.skippedFiles = skipped
                self.erroredFiles = errored
            }
        )
    }

    func import_from_doctor() async {
        guard let containerIdentifier = Bundle.main.object(forInfoDictionaryKey:
            "CloudKitContainerIdentifier") as? String
        else {
            await MainActor.run {
                erroredFiles = [ImportResult(filename: "Config", message: "Could not get container identifier from Info.plist")]
            }
            return
        }
        let filemanager = FileManager.default
        guard let dirURL = filemanager.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            await MainActor.run {
                erroredFiles = [ImportResult(filename: "iCloud", message: "Could not get iCloud container URL")]
            }
            return
        }

        await MainActor.run {
            totalFiles = 0
        }

        var err = nana_deinit()
        if err != 0 {
            fatalError("Failed to de-init libnana! With error:\(err)")
        }

        // Call nana_doctor with the directory path
        let resultPtr = dirURL.path().withCString { cString in
            let resultPtr = nana_doctor(cString)

            err = nana_init(cString)
            if err != 0 {
                fatalError("Failed to init libnana! With error:\(err)")
            }
            return resultPtr
        }

        // Parse the double-null-terminated string into an array of strings
        var files: [String] = []
        var maybePtr = resultPtr
        while let unwrappedPtr = maybePtr {
            guard unwrappedPtr.pointee != 0 else {
                break
            }
            let str = String(cString: unwrappedPtr)
            if !str.isEmpty {
                files.append(str)
            }
            maybePtr = unwrappedPtr.advanced(by: str.utf8.count + 1)
        }

        await MainActor.run {
            totalFiles = files.count
        }

        await importFiles(
            files,
            copy: true,
            addExt: true,
            onProgress: { complete, skipped, errored in
                self.completeFiles = complete
                self.skippedFiles = skipped
                self.erroredFiles = errored
            }
        )

        nana_doctor_finish()
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
                            Task.detached(priority: .userInitiated) {
                                try await import_from_dir(result: result)
                            }
                        }
                        Button {
                            action = "doctor"
                            Task.detached(priority: .userInitiated) {
                                await import_from_doctor()
                            }
                        } label: {
                            Label("Fix problems with data", systemImage: "stethoscope")
                        }
                        Spacer()
                        Progress(action: action,
                                 totalFiles: totalFiles,
                                 skippedFiles: skippedFiles,
                                 erroredFiles: erroredFiles,
                                 completeFiles: completeFiles)
                    }
                    .padding()
                }
            }.frame(minWidth: 250, maxWidth: .infinity, minHeight: 250, maxHeight: .infinity)
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

#Preview("Settings") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 0,
        skippedFiles: [],
        erroredFiles: [],
        completeFiles: [],
        action: ""
    )
}

#Preview("Settings Import 50%") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 10,
        skippedFiles: [],
        erroredFiles: [],
        completeFiles: [
            ImportResult(filename: "note1.md", message: ""),
            ImportResult(filename: "note2.md", message: ""),
            ImportResult(filename: "note3.md", message: ""),
            ImportResult(filename: "note4.md", message: ""),
            ImportResult(filename: "note5.md", message: ""),
        ],
        action: "import"
    )
}

#Preview("Settings Import Complete") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 10,
        skippedFiles: [],
        erroredFiles: [],
        completeFiles: (1 ... 10).map { ImportResult(filename: "note\($0).md", message: "") },
        action: "import"
    )
}

#Preview("Settings Import Complete With Skip") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 10,
        skippedFiles: [ImportResult(filename: "image.png", message: "File isn't a note.")],
        erroredFiles: [],
        completeFiles: (1 ... 9).map { ImportResult(filename: "note\($0).md", message: "") },
        action: "import"
    )
}

#Preview("Settings Import Failed") {
    GeneralSettingsView(
        showFileImporter: false,
        totalFiles: 10,
        skippedFiles: [],
        erroredFiles: [ImportResult(filename: "broken.md", message: "Something went wrong while importing: buffer overflow")],
        completeFiles: (1 ... 9).map { ImportResult(filename: "note\($0).md", message: "") },
        action: "import"
    )
}
