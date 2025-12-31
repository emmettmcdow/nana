//
//  Files.swift
//  nana
//
//  Created by Emmett McDow on 3/2/25.
//

import SwiftUI

struct FileList: View {
    @Binding var visible: Bool
    @Binding var results: [SearchResult]
    var onSelect: (SearchResult) -> Void
    var onChange: (String) -> Void
    var closeList: () -> Void

    @State private var query: String = ""
    @State private var hoverClose = false
    @FocusState private var queryFocused: Bool

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)

        GeometryReader { geometry in
            ZStack {
                if visible {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            onChange("")
                            closeList()
                        }.keyboardShortcut("k")
                        .transition(.opacity)
                }

                if visible {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20))
                                .foregroundColor(palette.tertiary)
                            TextField(
                                "",
                                text: $query
                            )
                            .focused($queryFocused)
                            .font(.system(size: 20))
                            .foregroundStyle(palette.foreground)
                            .accentColor(palette.foreground)
                            .textFieldStyle(.plain)
                            .onChange(of: query, initial: true) { _, newtext in
                                onChange(newtext)
                            }
                            Spacer()
                            Button(action: { onChange(""); closeList() }) {
                                ZStack {
                                    Circle()
                                        .fill(palette.background)
                                        .frame(width: 25, height: 25)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 20))
                                        .foregroundColor(palette.tertiary.mix(with: .black, by: hoverClose ? 0.2 : 0.0))
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .onHover { _ in
                                self.hoverClose.toggle()
                            }
                        }
                        .padding()

                        Results(results: results, onSelect: onSelect)
                    }
                    .frame(idealWidth: 300, maxWidth: min(geometry.size.width * 0.6, 500), maxHeight: geometry.size.height * 0.6)
                    .background(palette.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .transition(.push(from: .top))
                }
            }
            .onAppear {
                queryFocused = true
            }
            .onChange(of: visible) { _, _ in
                queryFocused = true
            }
            .preferredColorScheme({
                switch preference {
                case .light: .light
                case .dark: .dark
                case .system: nil
                }
            }())
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    NSCursor.arrow.push()
                case .ended:
                    NSCursor.pop()
                }
            }
            .onExitCommand { closeList() }
        }
        .animation(.spring(duration: 0.15), value: visible)
    }
}

struct Results: View {
    var results: [SearchResult]
    var onSelect: (SearchResult) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results) { result in
                    ResultRow(result: result, onSelect: onSelect)
                }
            }
        }
    }
}

func hilightedText(str: String, highlights: [Int]) -> AttributedString {
    @AppStorage("colorSchemePreference") var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) var colorScheme

    var styled = AttributedString(str)
    if str.isEmpty {
        return styled
    }

    let palette = Palette.forPreference(preference, colorScheme: colorScheme)
    for i in stride(from: 0, to: highlights.count, by: 2) {
        let highlight_start_i = highlights[i]
        let highlight_end_i = highlights[i + 1]
        guard highlight_end_i > highlight_start_i else { break }

        let startIndex = styled.index(styled.startIndex, offsetByUnicodeScalars: highlight_start_i)
        let endIndex = styled.index(styled.startIndex, offsetByUnicodeScalars: highlight_end_i)
        styled[startIndex ..< endIndex].backgroundColor = palette.background.mix(with: .white, by: 0.2)
        styled[startIndex ..< endIndex].foregroundColor = palette.foreground.mix(with: .black, by: 0.2)
    }
    return styled
}

struct ResultRow: View {
    var result: SearchResult
    var onSelect: (SearchResult) -> Void
    @State private var isHovered = false

    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        let ROW_SPACE = 3.0
        let formatted_pct = String(format: "%.1f", result.similarity * 100)

        HStack {
            VStack(alignment: .leading) {
                HStack {
                    Text(result.note.title)
                        .foregroundStyle(palette.foreground)
                        .bold()
                    if result.similarity != 0 {
                        Text("\(formatted_pct)%")
                            .foregroundStyle(palette.tertiary)
                            .italic()
                    }
                }
                Text(hilightedText(str: result.preview, highlights: result.highlights))
                    .lineLimit(3)
                    .foregroundStyle(palette.tertiary)
                    .italic()
            }
            .padding(.horizontal)
            .padding(.vertical, ROW_SPACE)
            Spacer()
            VStack {
                Text(result.note.modified.formatted(date: .long, time: .omitted))
                    .foregroundStyle(palette.tertiary)
                    .italic()
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, ROW_SPACE)
        }
        .background(palette.background.mix(with: palette.foreground, by: isHovered ? 0.1 : 0.0))
        .onHover { _ in
            isHovered.toggle()
        }
        .onTapGesture {
            onSelect(self.result)
        }
        .preferredColorScheme({
            switch preference {
            case .light: .light
            case .dark: .dark
            case .system: nil
            }
        }())
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

let li1 = "Donec interdum turpis non ipsum venenatis porttitor. Sed malesuada tempor ultricies. Morbi at elit elit. Proin id ligula consequat ipsum mollis pharetra. Praesent in tempor purus. Aenean sapien risus, maximus id elit ac, ullamcorper sollicitudin eros. Nulla blandit nec nisi et iaculis. Donec congue rutrum massa. Nulla congue augue non metus pharetra consectetur. Praesent sed tellus quis leo blandit sollicitudin. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos."

let li2 = "Pellentesque non iaculis purus. Maecenas laoreet feugiat massa in volutpat. Ut non nunc eleifend, tincidunt justo non, consequat ipsum. Ut quis nunc velit. Suspendisse consectetur turpis vel lectus faucibus semper et non elit. Etiam a fringilla lacus, nec scelerisque dui. Nulla quis orci tortor. Etiam nec scelerisque diam, sit amet blandit tellus. Nunc tortor nisi, volutpat id nibh et, ultrices molestie sem. Curabitur quis sem mi. Pellentesque odio eros, finibus luctus rutrum eu, consequat ut nulla. In et ipsum euismod, gravida augue quis, mattis nulla. Phasellus tristique accumsan justo sed dapibus. Pellentesque felis erat, tempus ac aliquam sed, interdum id mauris."

let li3 = "Aenean at mauris est. Etiam felis velit, tempor a ipsum quis, ornare ornare orci. Phasellus vehicula fermentum justo quis dictum. Sed sollicitudin quam augue, placerat gravida libero lacinia vitae. Vivamus lobortis mollis libero quis cursus. Vestibulum erat arcu, tincidunt ac lacus vel, luctus tincidunt magna. Duis rutrum at sapien et finibus. Proin lectus lacus, laoreet vitae auctor vitae, congue at nisi. Phasellus orci nisl, imperdiet ac magna eget, ornare dignissim sapien. Nullam ultricies dui ornare ante eleifend, at faucibus quam facilisis. Nulla tempus eros tincidunt porttitor hendrerit."

let pretty_highlights = [5, 11, 0, 0, 0, 0, 0, 0, 0, 0]
let it_ok = [0, 4, 7, 13, 0, 0, 0, 0, 0, 0]

#Preview("Notes") {
    @Previewable @State var visible = true
    @Previewable @State var results: [SearchResult] = [
        SearchResult(note: Note(id: 0, created: Date(), modified: Date(), content: li1, title: "How to train your dragon"), preview: "It's a pretty ok movie", highlights: it_ok),
        SearchResult(note: Note(id: 1, created: Date(), modified: Date(), content: li2, title: "Goodfellas"), preview: "Also pretty good.", highlights: pretty_highlights),
        SearchResult(note: Note(id: 2, created: Date(), modified: Date(), content: li3, title: "Toy Story"), preview: "Now we're talking baby. This is CINEMA."),
        SearchResult(note: Note(id: 3, created: Date(), modified: Date(), content: li3, title: "foo"), preview: "zim"),
        SearchResult(note: Note(id: 4, created: Date(), modified: Date(), content: li3, title: "foo"), preview: "zam"),
        SearchResult(note: Note(id: 5, created: Date(), modified: Date(), content: li3, title: "foo"), preview: "zot"),
        SearchResult(note: Note(id: 6, created: Date(), modified: Date(), content: li3, title: "foo"), preview: "zing"),
    ]
    FileList(visible: $visible, results: $results,
             onSelect: { (n: SearchResult) in print(n.note.id) },
             onChange: { (q: String) in print(q) },
             closeList: { () in print("closed") })
}
