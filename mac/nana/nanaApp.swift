//
//  nanaApp.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI

/// Applies nana's chrome to the hosting window: a transparent, separator-less
/// titlebar so the canvas can run edge-to-edge.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar?.showsBaselineSeparator = false
        }
    }
}

@main
struct nanaApp: App {
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @AppStorage("fontSize") private var fontSize: Double = 14
    @Environment(\.colorScheme) private var colorScheme

    var body: some Scene {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)

        WindowGroup {
            NanaCanvas()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.background)
                .background(WindowConfigurator())
                .preferredColorScheme({
                    switch preference {
                    case .light: .light
                    case .dark: .dark
                    case .system: nil
                    }
                }())
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .commands {
            CommandGroup(before: .toolbar) {
                Button("Increase Font Size") {
                    fontSize = min(fontSize + 1, 64)
                }
                .keyboardShortcut("+")
                Button("Decrease Font Size") {
                    fontSize = max(fontSize - 1, 1)
                }
                .keyboardShortcut("-")
                Divider()
            }
        }

        #if os(macOS)
            Settings {
                GeneralSettingsView()
            }
            .defaultSize(width: 500, height: 400)
        #endif
    }
}
