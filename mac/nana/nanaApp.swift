//
//  nanaApp.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI

import NanaKit

@main
struct nanaApp: App {
    init() {
        let frameworkBundle = Bundle.main
        guard let filePath = frameworkBundle.path(forResource: "model", ofType: "onnx") else {
            print("File not found")
            return
        }
        let err = nana_init(filePath, UInt32(filePath.count))
        if (err != 0) {
            fatalError("Failed to init libnana! With error:\(err)")
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }.windowStyle(HiddenTitleBarWindowStyle())
    }
}
