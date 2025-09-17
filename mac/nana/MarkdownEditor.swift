import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    // Optional configuration
    var font: NSFont = .systemFont(ofSize: 14)
    var backgroundColor: NSColor = .textBackgroundColor
    var textColor: NSColor = .textColor
    var isEditable: Bool = true

    func makeNSView(context: Context) -> NSScrollView {
        // Create the text system components in the correct order
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer()

        // Connect the text system
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        // Configure text container - try with explicit width
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textContainer.lineFragmentPadding = 0

        // Create MarkdownTextView with a proper initial frame
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: textContainer)

        // Create scroll view
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        // Configure text view AFTER it has a proper frame
        textView.backgroundColor = backgroundColor
        textView.font = font
        textView.textColor = textColor
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator

        // Now set container to track the properly-sized text view
        textContainer.containerSize = NSSize(width: textView.frame.width - 16, height: CGFloat.greatestFiniteMagnitude)

        // Set initial text content
        textStorage.setAttributedString(NSAttributedString(string: text))

        // Set the stored font size and typing attributes before formatting
        textView.updateBaseFontSize(font.pointSize)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
        ]

        textView.refreshMarkdownFormatting()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context _: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }

        // Update text if it changed externally
        if textView.string != text {
            textView.string = text
            textView.refreshMarkdownFormatting()
        }

        // Update font, colors, and other properties if they changed
        let currentSize = textView.font?.pointSize ?? 0
        let newSize = font.pointSize
        if currentSize != newSize {
            textView.font = font
            textView.updateBaseFontSize(newSize)
            textView.refreshMarkdownFormatting()
        }

        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.refreshMarkdownFormatting()
        }

        if textView.backgroundColor != backgroundColor {
            textView.backgroundColor = backgroundColor
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
