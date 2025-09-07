import SwiftUI
import AppKit

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    
    // Optional configuration
    var font: NSFont = NSFont.systemFont(ofSize: 14)
    var backgroundColor: NSColor = NSColor.textBackgroundColor
    var textColor: NSColor = NSColor.textColor
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
            .foregroundColor: textColor
        ]
        
        textView.refreshMarkdownFormatting()
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
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
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            return true
        }
    }
}

// MARK: - SwiftUI Preview and Example Usage

#if DEBUG
struct MarkdownEditor_Previews: PreviewProvider {
    static var previews: some View {
        MarkdownEditorExample()
            .frame(width: 600, height: 400)
    }
}

struct MarkdownEditorExample: View {
    @State private var text = """
# Welcome to Markdown Editor

This is a **live markdown editor** built with NSTextView and SwiftUI!

## Features

- **Bold text** formatting
- *Italic text* formatting  
- `Inline code` highlighting
- Headers of different sizes

### Code Example

```swift
let message = "Hello, World!"
print(message)
```

> This is a quote block that demonstrates
> how quoted text appears in the editor.

Try editing this text to see live formatting updates!
"""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Live Markdown Editor")
                .font(.title)
                .bold()
            
            MarkdownEditor(text: $text)
                .border(Color.gray.opacity(0.3))
            
            HStack {
                Text("Characters: \\(text.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
                    text = ""
                }
                Button("Reset") {
                    text = """
# Sample Document

Try typing **bold**, *italic*, or `code` text!

> Quote something interesting here.
"""
                }
            }
        }
        .padding()
    }
}
#endif