//
//  NanaCanvas.swift
//  nana
//
//  SwiftUI wrapper that drops the Zig-backed NanaCanvasView into the view tree.
//  This replaces the SwiftUI/NSTextView MarkdownEditor as the main editing surface.
//

import SwiftUI

struct NanaCanvas: NSViewRepresentable {
    func makeNSView(context _: Context) -> NanaCanvasView {
        NanaCanvasView(frame: .zero)
    }

    func updateNSView(_: NanaCanvasView, context _: Context) {
        // Immediate-mode: the view drives its own redraw loop, so there is nothing
        // to push from SwiftUI yet. State will flow in here once the editor grows one.
    }
}
