import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    // Optional configuration
    var palette: Palette
    var font: NSFont = .systemFont(ofSize: 14)
    var isEditable: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        // Create the text system components in the correct order
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer()

        // Connect the text system
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        // Configure text container to prevent horizontal scrolling
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textContainer.lineFragmentPadding = 0

        // Create MarkdownTextView with initial frame that will be auto-resized
        let textView = MarkdownTextView(frame: .zero, textContainer: textContainer)

        // Create scroll view
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false

        // Ensure no horizontal scrolling
        scrollView.contentView.postsBoundsChangedNotifications = true

        // Configure text view AFTER it has a proper frame
        textView.setPalette(palette: palette)
        textView.font = font
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.updateBaseFontSize(font.pointSize)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: palette.NSfg(),
        ]

        // Set initial text content
        textStorage.setAttributedString(NSAttributedString(string: text))
        textView.refreshMarkdownFormatting()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }

        // Update text if it changed externally
        let textChanged = textView.string != text
        let sizeChanged = font.pointSize != textView.baseFontSize()
        let fgChanged = textView.textColor != palette.NSfg()
        let bgChanged = textView.backgroundColor != palette.NSbg()
        if textChanged || sizeChanged || fgChanged || bgChanged {
            textView.string = text
            textView.font = font
            textView.updateBaseFontSize(font.pointSize)
            textView.setPalette(palette: palette)
            textView.refreshMarkdownFormatting()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MarkdownEditor

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            // Update the binding
            DispatchQueue.main.async {
                self.parent.text = textView.string
            }
        }

        // Optional: Handle other text view delegate methods as needed
        func textView(_: NSTextView, shouldChangeTextIn _: NSRange, replacementString _: String?) -> Bool {
            return true
        }
    }
}
