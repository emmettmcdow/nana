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

    private func nana_deinit() -> Int32 {
        return 0
    }

    private func nana_doctor() -> Int32 {
        return 0
    }
#else
    import NanaKit
#endif

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

private struct TitlebarChip: NSViewRepresentable {
    @ObservedObject var contextManager: ContextManager
    let onSwitch: (WorkspaceContext) -> Void
    let onAddNew: () -> Void

    final class Coordinator {
        var installed = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard !context.coordinator.installed else { return }
        DispatchQueue.main.async {
            guard !context.coordinator.installed,
                  let window = view.window else { return }

            let chip = ContextChip(
                contextManager: contextManager,
                onSwitch: onSwitch,
                onAddNew: onAddNew
            )
            let hosting = NSHostingView(rootView: chip)
            hosting.translatesAutoresizingMaskIntoConstraints = true
            hosting.autoresizingMask = [.height]
            let fitting = hosting.fittingSize
            hosting.frame = NSRect(x: 0, y: 0,
                                   width: max(fitting.width, 80),
                                   height: 28)

            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = hosting
            accessory.layoutAttribute = .leading

            window.addTitlebarAccessoryViewController(accessory)
            context.coordinator.installed = true
        }
    }
}

@main
struct nanaApp: App {
    @State private var startupRun: Bool = false
    @State private var switching: Bool = false
    @State private var needsInitialContext: Bool = false
    @State private var notesManager: NotesManager?
    @State private var showingToast = false
    @State private var toastMessage = ""
    @AppStorage("initializationFailed") private var initializationFailed = false
    @StateObject private var contextManager = ContextManager()

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @AppStorage("fontSize") private var fontSize: Double = 14
    @Environment(\.colorScheme) private var colorScheme

    private nonisolated func onStartup() async {
        guard !(await startupRun) else { return }

        let ctx: WorkspaceContext? = await MainActor.run {
            if let active = contextManager.activeContext {
                return active
            }
            return contextManager.bootstrapICloudIfNeeded()
        }

        guard let ctx else {
            await MainActor.run { needsInitialContext = true }
            return
        }

        await initWithContext(ctx)
    }

    private nonisolated func initWithContext(_ ctx: WorkspaceContext) async {
        let url: URL? = await MainActor.run { contextManager.startAccessing(ctx) }
        guard let url else {
            await MainActor.run {
                initializationFailed = true
                startupRun = true
                switching = false
            }
            return
        }

        let basedir = url.path()
        print("DEBUG: nana_init for context '\(ctx.displayName)' at \(basedir)")
        let err = nana_init(basedir)
        print("DEBUG: nana_init returned: \(err)")

        if err == 0 {
            // If this workspace has never been indexed (no nana metadata present), run doctor
            // to build embeddings for the existing markdown files in it.
            let metadata = url.appendingPathComponent(".dve_ids")
            if !FileManager.default.fileExists(atPath: metadata.path) {
                print("DEBUG: no embeddings found at \(basedir), running doctor")
                let dErr = nana_doctor()
                print("DEBUG: nana_doctor returned: \(dErr)")
            }
        }

        await MainActor.run {
            if err != 0 {
                initializationFailed = true
                startupRun = true
                switching = false
                return
            }
            notesManager = NotesManager()
            startupRun = true
            switching = false
        }
    }

    private func switchContext(to ctx: WorkspaceContext) {
        guard ctx.id != contextManager.activeID || notesManager == nil else { return }
        switching = true
        notesManager?.flushPendingSave()
        notesManager = nil
        contextManager.stopAccessing()
        _ = nana_deinit()
        contextManager.setActive(ctx.id)
        startupRun = false

        Task.detached {
            await initWithContext(ctx)
        }
    }

    private func presentAddContext() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a directory for the new context"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let entry = contextManager.addUserContext(url: url) else { return }

        if notesManager == nil {
            needsInitialContext = false
            contextManager.setActive(entry.id)
            switching = true
            Task.detached { await initWithContext(entry) }
        } else {
            switchContext(to: entry)
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
                if needsInitialContext {
                    VStack(spacing: 20) {
                        Text("Welcome to nana")
                            .font(.title)
                        Text("Pick a directory to use as your first context")
                            .foregroundColor(.secondary)
                        Button("Choose Directory...") {
                            presentAddContext()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background)
                } else if !startupRun || switching {
                    HStack {
                        VStack {
                            Spacer()
                            LoadingBanana()
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background)
                } else if let notesManager {
                    ContentView()
                        .environmentObject(notesManager)
                        .disabled(initializationFailed)
                }

                ToastView(showingToast: $showingToast, message: $toastMessage)
            }
            .background(palette.background)
            .disabled(initializationFailed)
            .background(WindowConfigurator())
            .background(TitlebarChip(
                contextManager: contextManager,
                onSwitch: { ctx in switchContext(to: ctx) },
                onAddNew: { presentAddContext() }
            ))
            .onAppear {
                Task.detached {
                    await onStartup()
                }
            }
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
                    .environmentObject(contextManager)
            }
            .defaultSize(width: 600, height: 500)
        #endif
    }
}
