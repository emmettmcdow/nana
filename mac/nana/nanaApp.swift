//
//  nanaApp.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI

#if !DISABLE_NANAKIT
    import NanaKit
#endif

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
            CommandGroup(after: .newItem) {
                Button("Choose Notes Folder…") { Workspace.choose() }
                Divider()
            }
            CommandGroup(before: .toolbar) {
                // Font size lives in Zig, which owns clamping and persistence; these just nudge
                // it. Nothing to store on this side.
                Button("Increase Font Size") { nana_render_adjust_font_size(1) }
                    .keyboardShortcut("+")
                Button("Decrease Font Size") { nana_render_adjust_font_size(-1) }
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
