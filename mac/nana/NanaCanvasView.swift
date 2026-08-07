//
//  NanaCanvasView.swift
//  nana
//
//  Host for the Zig render scaffold. An NSView that drives an immediate-mode loop:
//  ~60x/second it asks the view to redraw, and in draw(_:) it hands the current
//  CGContext + size + an input snapshot to the Zig `nana_render_frame`.
//
//  AppKit lives here; all drawing happens in Zig (Core Text / Core Graphics).
//

import AppKit

#if DISABLE_NANAKIT

    // SwiftUI previews compile with NanaKit stubbed out — provide an inert view so
    // the preview target still builds without the nana_render_* symbols.
    final class NanaCanvasView: NSView {}

    enum Workspace {
        static func restore() -> String? { nil }
        @discardableResult static func choose() -> Bool { false }
    }

#else

    import NanaKit

    /// Workspace access.
    ///
    /// Under the sandbox, a directory the user picked is only reachable through a
    /// security-scoped bookmark — a Foundation concept with no Zig equivalent, so resolving and
    /// holding it is the shim's job. Zig is told a plain path and nothing more.
    enum Workspace {
        private static let bookmarkKey = "workspaceBookmark"

        /// The scope currently held open. Released only when replaced: access lasts as long as
        /// the workspace is in use, not just as long as the call that opened it.
        private static var accessing: URL?

        /// Resolve the stored bookmark, if there is one, and start accessing it.
        /// Returns the path to hand to Zig at startup.
        static func restore() -> String? {
            guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                // A bookmark we can't resolve is worse than none — drop it so the next launch
                // falls back to the default rather than failing the same way forever.
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                return nil
            }
            guard beginAccess(url) else { return nil }
            // A stale bookmark still resolves, but re-issue it so it doesn't decay further.
            if stale { store(url) }
            return url.path
        }

        /// Ask for a directory and switch to it. Returns whether the switch happened.
        @discardableResult
        static func choose() -> Bool {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Choose a folder for your notes"
            guard panel.runModal() == .OK, let url = panel.url else { return false }

            guard store(url), beginAccess(url) else { return false }
            return nana_render_set_workspace(url.path)
        }

        /// Persist a bookmark for `url`. The panel's grant is what makes the bookmark usable
        /// later, so this has to happen while that grant is still in effect.
        @discardableResult
        private static func store(_ url: URL) -> Bool {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return false }
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            return true
        }

        private static func beginAccess(_ url: URL) -> Bool {
            if let current = accessing {
                current.stopAccessingSecurityScopedResource()
                accessing = nil
            }
            guard url.startAccessingSecurityScopedResource() else { return false }
            accessing = url
            return true
        }
    }

    final class NanaCanvasView: NSView, NSMenuItemValidation {
        private var timer: Timer?

        // Input state, accumulated from events and snapshotted each frame.
        private var mousePoint = CGPoint.zero
        private var mouseIsDown = false
        private var modifiers: UInt32 = 0
        private var scrollDelta: Double = 0
        private var pendingText = ""
        private var backspaceCount: UInt32 = 0
        private var escapeCount: UInt32 = 0
        private var upCount: UInt32 = 0
        private var downCount: UInt32 = 0
        private var leftCount: UInt32 = 0
        private var rightCount: UInt32 = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            commonInit()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            commonInit()
        }

        private func commonInit() {
            wantsLayer = true
            // A previously chosen workspace if there is one, otherwise nil so Zig uses its
            // default. Passed at init rather than switched to afterwards, so a user with their
            // own folder never has the default one created behind their back.
            nana_render_init(Workspace.restore())
            startLoop()
        }

        deinit {
            timer?.invalidate()
            nana_render_deinit()
        }

        // Top-left origin (y grows downward) to match the Zig canvas coordinate space.
        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        // MARK: - Loop

        private func startLoop() {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            // .common so the loop keeps ticking during live resize / menu tracking.
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        // MARK: - Draw

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }

            var input = NanaInput()
            input.mouse_x = Double(mousePoint.x)
            input.mouse_y = Double(mousePoint.y)
            input.mouse_down = mouseIsDown
            input.modifiers = modifiers

            // Resolved here because the same answer drives the titlebar: whatever appearance
            // AppKit settled on for this view is the one Zig should paint to match.
            input.system_dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

            input.scroll_dy = scrollDelta
            scrollDelta = 0

            // For each of these types of input, we think of it in terms of "consumption". We read
            // some data, and we are using it up.
            var textBytes = Array(pendingText.utf8)
            pendingText = ""

            input.backspaces = backspaceCount
            backspaceCount = 0

            input.escapes = escapeCount
            escapeCount = 0

            input.ups = upCount
            upCount = 0
            input.downs = downCount
            downCount = 0
            input.lefts = leftCount
            leftCount = 0
            input.rights = rightCount
            rightCount = 0

            // The buffer is borrowed for the duration of the call, so it has to outlive it —
            // hence passing it in from an enclosing scope rather than building it inline.
            textBytes.withUnsafeBufferPointer { buf in
                input.text_utf8 = buf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }
                input.text_len = UInt32(buf.count)
                nana_render_frame(ctx, Double(bounds.width), Double(bounds.height), &input)
            }
        }

        // MARK: - Clipboard
        //
        // The pasteboard is an AppKit service, so it lives here; what counts as "selected"
        // lives in Zig. Pasted text needs no special path — it goes in as ordinary input.

        /// Pull the current selection out of Zig, sizing the buffer from it first.
        private func takeSelection(cut: Bool) -> String? {
            let len = nana_render_selection_len()
            guard len > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: Int(len))
            let written = buf.withUnsafeMutableBufferPointer { p in
                cut ? nana_render_cut_selection(p.baseAddress, len)
                    : nana_render_copy_selection(p.baseAddress, len)
            }
            guard written > 0 else { return nil }
            let bytes = buf.prefix(Int(written)).map { UInt8(bitPattern: $0) }
            return String(bytes: bytes, encoding: .utf8)
        }

        private func writeToPasteboard(_ s: String) {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(s, forType: .string)
        }

        @objc func copy(_: Any?) {
            guard let s = takeSelection(cut: false) else { return }
            writeToPasteboard(s)
        }

        @objc func cut(_: Any?) {
            guard let s = takeSelection(cut: true) else { return }
            writeToPasteboard(s)
            needsDisplay = true
        }

        @objc func paste(_: Any?) {
            guard let s = NSPasteboard.general.string(forType: .string) else { return }
            pendingText += s
            needsDisplay = true
        }

        @objc override func selectAll(_: Any?) {
            nana_render_select_all()
            needsDisplay = true
        }

        // MARK: - Undo

        @objc func undo(_: Any?) {
            _ = nana_render_undo()
            needsDisplay = true
        }

        @objc func redo(_: Any?) {
            _ = nana_render_redo()
            needsDisplay = true
        }

        /// Handle the editing shortcuts directly rather than relying on an Edit menu being
        /// present. Returning true stops the event before the main menu sees it, so the menu
        /// items (which route to the `@objc` methods above) can't also fire for the same press.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }

            // Cmd+Shift+Z is redo; every other shortcut here is plain Cmd.
            if mods == [.command, .shift], key == "z" {
                redo(nil)
                return true
            }
            guard mods == .command else { return false }
            switch key {
            case "c": copy(nil)
            case "x": cut(nil)
            case "v": paste(nil)
            case "a": selectAll(nil)
            case "z": undo(nil)
            default: return false
            }
            return true
        }

        // MARK: - Context menu
        //
        // Built here for the same reason the pasteboard is: it is an AppKit service. The items
        // route to the very same handlers as the Cmd shortcuts, so there is one implementation of
        // each command and no way for the two routes to drift.

        /// Right-click puts up the editing menu. A selection is left alone — the user is almost
        /// certainly acting on it — but with nothing selected the caret follows the click, so a
        /// Paste from the menu lands where they pointed rather than wherever the caret was left.
        override func rightMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let point = convert(event.locationInWindow, from: nil)
            mousePoint = point

            if nana_render_selection_len() == 0 {
                nana_render_place_caret(Double(point.x), Double(point.y))
                needsDisplay = true
            }

            let menu = NSMenu()
            for (title, action) in [
                ("Cut", #selector(cut(_:))),
                ("Copy", #selector(copy(_:))),
                ("Paste", #selector(paste(_:))),
            ] {
                menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
            // Explicit, since the view is not in the responder chain AppKit walks for a menu it
            // was not asked to validate through the main menu.
            for item in menu.items { item.target = self }

            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        /// Grey out what cannot happen, rather than offering it and doing nothing. The selection
        /// length is read live from Zig — it is the same answer the command itself would get.
        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            switch item.action {
            case #selector(cut(_:)), #selector(copy(_:)):
                return nana_render_selection_len() > 0
            case #selector(paste(_:)):
                return NSPasteboard.general.canReadObject(forClasses: [NSString.self], options: nil)
            default:
                return true
            }
        }

        // MARK: - Input

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for ta in trackingAreas { removeTrackingArea(ta) }
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                ))
        }

        override func mouseMoved(with event: NSEvent) {
            mousePoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            mousePoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseDown(with event: NSEvent) {
            mouseIsDown = true
            mousePoint = convert(event.locationInWindow, from: nil)
            window?.makeFirstResponder(self)
        }

        override func mouseUp(with _: NSEvent) {
            mouseIsDown = false
        }

        override func scrollWheel(with event: NSEvent) {
            // Accumulate rather than assign: several scroll events can land between two frames,
            // and dropping all but the last would lose most of a fast flick.
            //
            // `scrollingDeltaY` is the precise-pixel value on trackpads and Magic Mouse, and
            // falls back to line-sized steps for a notched wheel. `hasPreciseScrollingDeltas`
            // tells the two apart; only the latter needs scaling up to feel right.
            if event.hasPreciseScrollingDeltas {
                scrollDelta += event.scrollingDeltaY
            } else {
                scrollDelta += event.scrollingDeltaY * 16
            }
        }

        override func keyDown(with event: NSEvent) {
            // A Command-modified press is a shortcut, not text. Without this, anything not
            // claimed by performKeyEquivalent (Cmd+S, Cmd+W, ...) would insert its bare
            // character into the document.
            if event.modifierFlags.contains(.command) { return }

            // The Backspace key (labeled "delete" on Mac keyboards) is keyCode 51. It's a
            // key press, not a modifier — count it instead of appending its control
            // character to the text buffer.
            if event.keyCode == 51 {
                backspaceCount += 1
            } else if event.keyCode == 53 {
                escapeCount += 1
            } else if event.keyCode == 126 {
                upCount += 1
            } else if event.keyCode == 125 {
                downCount += 1
            } else if event.keyCode == 123 {
                leftCount += 1
            } else if event.keyCode == 124 {
                rightCount += 1
            } else if event.keyCode == 36 || event.keyCode == 76 {
                // Return (36) and numpad Enter (76) report "\r" via `characters`;
                // normalize to "\n" and let it flow through the normal text path.
                pendingText += "\n"
            } else if let chars = event.characters, !chars.isEmpty {
                pendingText += chars
            }
        }

        override func flagsChanged(with event: NSEvent) {
            var m: UInt32 = 0
            let flags = event.modifierFlags
            if flags.contains(.shift) { m |= 1 << 0 }
            if flags.contains(.control) { m |= 1 << 1 }
            if flags.contains(.option) { m |= 1 << 2 }
            if flags.contains(.command) { m |= 1 << 3 }
            modifiers = m
        }
    }

#endif
