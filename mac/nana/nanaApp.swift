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
        let err = nana_init()
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
