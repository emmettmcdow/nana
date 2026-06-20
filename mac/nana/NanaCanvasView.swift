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

#else

    import NanaKit

    final class NanaCanvasView: NSView {
        private var timer: Timer?

        // Input state, accumulated from events and snapshotted each frame.
        private var mousePoint = CGPoint.zero
        private var mouseIsDown = false
        private var modifiers: UInt32 = 0
        private var pendingText = ""
        private var backspaceCount: UInt32 = 0
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
            nana_render_init()
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

            let bytes = Array(pendingText.utf8.prefix(63))
            withUnsafeMutableBytes(of: &input.text_utf8) { raw in
                for (i, b) in bytes.enumerated() { raw[i] = b }
                raw[bytes.count] = 0
            }

            // For each of these types of input, we think of it in terms of "consumption". We read
            // some data, and we are using it up.
            input.text_len = UInt32(bytes.count)
            pendingText = ""

            input.backspaces = backspaceCount
            backspaceCount = 0

            input.ups = upCount
            upCount = 0
            input.downs = downCount
            downCount = 0
            input.lefts = leftCount
            leftCount = 0
            input.rights = rightCount
            rightCount = 0

            nana_render_frame(ctx, Double(bounds.width), Double(bounds.height), &input)
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

        override func keyDown(with event: NSEvent) {
            // The Backspace key (labeled "delete" on Mac keyboards) is keyCode 51. It's a
            // key press, not a modifier — count it instead of appending its control
            // character to the text buffer.
            if event.keyCode == 51 {
                backspaceCount += 1
            } else if event.keyCode == 126 {
                upCount += 1
            } else if event.keyCode == 125 {
                downCount += 1
            } else if event.keyCode == 123 {
                leftCount += 1
            } else if event.keyCode == 124 {
                rightCount += 1
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
