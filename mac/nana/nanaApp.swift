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

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
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
            self.startupRun = true
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
                } else {
                    ContentView()
                        .disabled(!startupRun)
                }
            }
            .onAppear {
                Task.detached {
                    await onStartup()
                }
            }
        }.windowStyle(HiddenTitleBarWindowStyle())

        #if os(macOS)
            Settings {
                GeneralSettingsView()
            }
        #endif
    }
}
