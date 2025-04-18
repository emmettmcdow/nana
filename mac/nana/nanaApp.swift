//
//  nanaApp.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI
import Foundation

import NanaKit

@main
struct nanaApp: App {
    init() {
        #if DEBUG
            let basedir = "./"
        #else
            let filemanager = FileManager.default
            guard let url = filemanager.url(forUbiquityContainerIdentifier: "iCloud.userdata") else {
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
        
        let frameworkBundle = Bundle.main
        guard let modelPath = frameworkBundle.path(forResource: "model", ofType: "onnx") else {
            print("File not found")
            return
        }
        let err = nana_init(basedir, UInt32(basedir.count), modelPath, UInt32(modelPath.count))
        if (err != 0) {
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
