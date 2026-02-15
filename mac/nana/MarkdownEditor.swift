import AppKit
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var highlightRange: NSRange?

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
        textContainer.widthTracksTextView = false // We'll manage width manually to account for insets
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

        textView.selectedTextAttributes = [
            NSAttributedString.Key.backgroundColor: palette.NStert(), // Change background color
        ]

        // Add padding to prevent text from interfering with buttons
        textView.textContainerInset = NSSize(width: 60, height: 30)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: palette.NSfg(),
        ]

        // Set initial text content
        textStorage.setAttributedString(NSAttributedString(string: text))
        textView.refreshMarkdownFormatting()

        // Set up frame change observer to update text container width when resizing
        context.coordinator.setupFrameObserver(for: scrollView, textView: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }

        // Ensure text container width is correct (important for first render)
        context.coordinator.updateTextContainerWidth(scrollView: scrollView, textView: textView)

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

        // Scroll to and highlight search result
        if let range = highlightRange {
            let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: textView.string.unicodeScalars.count))
            if safeRange.length > 0 {
                textView.scrollRangeToVisible(safeRange)

                let highlightColor = palette.NStert()

                // Flash to full opacity, then fade out over ~1 second
                textView.textStorage?.addAttribute(.backgroundColor, value: highlightColor.withAlphaComponent(1.0), range: safeRange)

                let flashDuration = 0.1
                let fadeDuration = 0.9
                let fadeSteps = 30
                let fadeInterval = fadeDuration / Double(fadeSteps)
                for step in 0...fadeSteps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + flashDuration + fadeInterval * Double(step)) {
                        let alpha = 0.8 * (1.0 - Double(step) / Double(fadeSteps))
                        if alpha > 0 {
                            textView.textStorage?.addAttribute(.backgroundColor, value: highlightColor.withAlphaComponent(alpha), range: safeRange)
                        } else {
                            textView.textStorage?.removeAttribute(.backgroundColor, range: safeRange)
                            textView.refreshMarkdownFormatting()
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.highlightRange = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        let parent: MarkdownEditor
        private var frameObserver: NSObjectProtocol?

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        deinit {
            if let observer = frameObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func setupFrameObserver(for scrollView: NSScrollView, textView: NSTextView) {
            // Update container width initially
            updateTextContainerWidth(scrollView: scrollView, textView: textView)

            // Observe frame changes
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak textView] _ in
                guard let textView = textView,
                      let scrollView = textView.enclosingScrollView else { return }
                self.updateTextContainerWidth(scrollView: scrollView, textView: textView)
            }
        }

        func updateTextContainerWidth(scrollView: NSScrollView, textView: NSTextView) {
            guard let textContainer = textView.textContainer else { return }

            // Calculate available width: scroll view's content width minus text insets
            let scrollViewWidth = scrollView.contentView.bounds.width
            let horizontalInset = textView.textContainerInset.width * 2 // Inset on both sides
            let availableWidth = max(0, scrollViewWidth - horizontalInset)

            // Update text container width
            textContainer.containerSize = NSSize(
                width: availableWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            // Auto-scroll if cursor is near the bottom of the visible area
            if let scrollView = textView.enclosingScrollView,
               let layoutManager = textView.layoutManager
            {
                let insertionPoint = textView.selectedRange().location
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(insertionPoint, textView.string.count - 1))
                var lineRect = layoutManager.lineFragmentRect(forGlyphAt: max(0, glyphIndex), effectiveRange: nil)

                // Account for text container inset
                lineRect.origin.y += textView.textContainerInset.height

                let visibleRect = scrollView.contentView.bounds
                let bottomMargin: CGFloat = 160

                let cursorBottom = lineRect.origin.y + lineRect.height
                let visibleBottom = visibleRect.origin.y + visibleRect.height

                if cursorBottom > visibleBottom - bottomMargin {
                    let scrollPoint = NSPoint(
                        x: visibleRect.origin.x,
                        y: cursorBottom - visibleRect.height + bottomMargin
                    )
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.3
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        scrollView.contentView.animator().setBoundsOrigin(scrollPoint)
                    }
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }

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
