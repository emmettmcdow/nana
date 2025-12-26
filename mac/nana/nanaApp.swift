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

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @AppStorage("fontSize") private var fontSize: Double = 14
    @Environment(\.colorScheme) private var colorScheme

    private nonisolated func onStartup() async {
        guard !(await startupRun) else { return }

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
        let err = nana_init(basedir)
        if err != 0 {
            fatalError("Failed to init libnana! With error:\(err)")
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
                        .disabled(!startupRun)
                }
                ToastView(showingToast: $showingToast, message: $toastMessage)
            }
            .onAppear {
                Task.detached {
                    await onStartup()
                }
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
