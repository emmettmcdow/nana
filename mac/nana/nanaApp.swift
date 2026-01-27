//
//  nanaApp.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import Foundation
import SwiftUI

#if DISABLE_NANAKIT
    private func nana_init(_: UnsafePointer<Int8>) -> Int {
        Thread.sleep(forTimeInterval: 5.0)
        return 0
    }
#else
    import NanaKit
#endif

@main
struct nanaApp: App {
    @State private var startupRun: Bool = false
    @State private var notesManager: NotesManager?
    @State private var showingToast = false
    @State private var toastMessage = ""
    @AppStorage("initializationFailed") private var initializationFailed = false

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @AppStorage("fontSize") private var fontSize: Double = 14
    @Environment(\.colorScheme) private var colorScheme

    #if DEBUG
    @State private var showingDirectoryPicker = true
    @State private var selectedBasedir: URL?
    #endif

    private nonisolated func onStartup() async {
        guard !(await startupRun) else { return }

        #if DEBUG
        guard let basedirURL = await selectedBasedir else {
            print("No basedir selected in debug mode")
            return
        }
        guard basedirURL.startAccessingSecurityScopedResource() else {
            print("DEBUG: Failed to access security scoped resource")
            return
        }
        let basedir = basedirURL.path()
        print("DEBUG: Using basedir: \(basedir)")
        #else
        guard let containerIdentifier = Bundle.main.object(forInfoDictionaryKey:
            "CloudKitContainerIdentifier") as? String
        else {
            print("Could not get container identifier from Info.plist")
            return
        }
        let filemanager = FileManager.default
        guard let url = filemanager.url(forUbiquityContainerIdentifier: containerIdentifier) else {
            print("Could not get url")
            return
        }
        do {
            try filemanager.startDownloadingUbiquitousItem(at: url)
        } catch {
            print("Could not dl url")
            return
        }
        let basedir = url.path()
        #endif

        let err = nana_init(basedir)
        print("DEBUG: nana_init returned: \(err)")
        if err != 0 {
            await MainActor.run {
                self.initializationFailed = true
                self.startupRun = true
            }
            return
        }
        await MainActor.run {
            self.notesManager = NotesManager()
            self.startupRun = true
        }
    }

    func toast(msg: String) {
        toastMessage = msg
        withAnimation {
            showingToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation {
                showingToast = false
            }
        }
    }

    var body: some Scene {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)

        WindowGroup {
            ZStack {
                #if DEBUG
                if showingDirectoryPicker {
                    VStack(spacing: 20) {
                        Text("Debug Mode")
                            .font(.title)
                        Text("Select a base directory for notes")
                            .foregroundColor(.secondary)
                        Button("Choose Directory...") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.message = "Select the base directory for your notes"
                            if panel.runModal() == .OK {
                                selectedBasedir = panel.url
                                showingDirectoryPicker = false
                                Task.detached {
                                    await onStartup()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background)
                } else if !startupRun {
                    HStack {
                        VStack {
                            Spacer()
                            LoadingBanana()
                        }
                        Spacer()
                    }
                    .background(palette.background)
                } else if let notesManager = notesManager {
                    ContentView()
                        .environmentObject(notesManager)
                        .disabled(initializationFailed)
                }
                #else
                if !startupRun {
                    HStack {
                        VStack {
                            Spacer()
                            LoadingBanana()
                        }
                        Spacer()
                    }
                    .background(palette.background)
                } else if let notesManager = notesManager {
                    ContentView()
                        .environmentObject(notesManager)
                        .disabled(initializationFailed)
                }
                #endif
                ToastView(showingToast: $showingToast, message: $toastMessage)
            }
            .disabled(initializationFailed)
            #if !DEBUG
            .onAppear {
                Task.detached {
                    await onStartup()
                }
            }
            #endif
            .alert("Initialization Error",
                   isPresented: $initializationFailed) {
                Button("OK") {}
            } message: {
                Text("An error occurred during startup. Please open Settings and click 'Doctor' in the Data tab to fix your data.")
            }
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Note") {
                    notesManager?.createNewNote()
                    toast(msg: "Created new note")
                }
                .keyboardShortcut("p")
            }

            CommandGroup(before: .toolbar) {
                Button("Increase Font Size") {
                    fontSize = min(fontSize + 1, 64)
                    toast(msg: "Increased font size")
                }
                .keyboardShortcut("+")
                Button("Decrease Font Size") {
                    fontSize = max(fontSize - 1, 1)
                    toast(msg: "Decreased font size")
                }
                .keyboardShortcut("-")
                Divider()
            }
        }

        #if os(macOS)
            Settings {
                GeneralSettingsView()
            }
            .defaultSize(width: 600, height: 500)
        #endif
    }
}
