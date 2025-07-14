//
//  nanaApp.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import Foundation
import SwiftUI

#if DEBUG
    func nana_init(_: UnsafePointer<Int8>, _: UInt32, _: UnsafePointer<Int8>, _: UInt32) -> Int {
        return 0
    }
#else
    import NanaKit
#endif

@main
struct nanaApp: App {
    init() {
        #if DEBUG
            let basedir = "./"
        #else
            let filemanager = FileManager.default
            guard let url = filemanager.url(forUbiquityContainerIdentifier: "iCloud.com.mcdow.nana.dev-container") else {
                print("Could not get url")
                return
            }
            do {
                try filemanager.startDownloadingUbiquitousItem(at: url)
            } catch {
                print("Could not dl url")
                return
            }
            let basedir = url.path
        #endif

        let err = nana_init(basedir, UInt32(basedir.count))
        if err != 0 {
            fatalError("Failed to init libnana! With error:\(err)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }.windowStyle(HiddenTitleBarWindowStyle())

        #if os(macOS)
            Settings {
                GeneralSettingsView()
            }
        #endif
    }
}
