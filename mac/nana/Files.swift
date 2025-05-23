//
//  Files.swift
//  nana
//
//  Created by Emmett McDow on 3/2/25.
//

import SwiftUI

struct FileList: View {
    @Binding var notes: [Note]
    var onSelect: (Note) -> Void
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
            ZStack() {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        onChange("")
                        closeList()
                    }
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundColor(palette.tertiary)
                        TextField(
                            "Query",
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
                        Button(action: {onChange("");closeList();}){
                            ZStack {
                                Circle()
                                    .fill(palette.background)
                                    .frame(width:25, height:25)
                                Image(systemName: "xmark")
                                    .font(.system(size: 20))
                                    .foregroundColor(palette.tertiary.mix(with: .black, by: hoverClose ? 0.2 : 0.0))
                            }
                        }.buttonStyle(PlainButtonStyle())
                        .onHover{ _ in
                            self.hoverClose.toggle()
                        }
                    }
                    .padding()
                    
                    Results(notes: notes, onSelect: onSelect)
                }
                .frame(idealWidth: 300, maxWidth: min(geometry.size.width * 0.6, 500), maxHeight: geometry.size.height * 0.6)
                .background(palette.background)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .onAppear {
            // Set the focus to the TextField when the view appears
            queryFocused = true
        }
        .preferredColorScheme({
            switch preference {
            case .light: .light
            case .dark: .dark
            case .system: nil
            }
        }())
    }
}

struct Results: View {
    var notes: [Note]
    var onSelect: (Note) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading) {
                ForEach(notes) { note in
                    ResultRow(note: note, onSelect: onSelect)
                }
            }
            .listStyle(.plain)
        }
    }
}

struct ResultRow: View{
    var note: Note
    var onSelect: (Note) -> Void
    @State private var isHovered = false
    
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        
        HStack(){
            Text(self.note.content)
                .lineLimit(3)
                .foregroundStyle(palette.foreground)
            Spacer()
            Text(Date.now.formatted(date: .long, time: .omitted))
                .foregroundStyle(palette.tertiary)
                .italic()
        }
        .background(palette.background.mix(with: palette.foreground, by: isHovered ? 0.1 : 0.0))
        .onHover { hovering in
            isHovered.toggle()
        }
        .onTapGesture {
            onSelect(self.note)
        }
        .padding([.leading, .trailing])
        .preferredColorScheme({
            switch preference {
            case .light: .light
            case .dark: .dark
            case .system: nil
            }
        }())
    }
}

let li1 = "Donec interdum turpis non ipsum venenatis porttitor. Sed malesuada tempor ultricies. Morbi at elit elit. Proin id ligula consequat ipsum mollis pharetra. Praesent in tempor purus. Aenean sapien risus, maximus id elit ac, ullamcorper sollicitudin eros. Nulla blandit nec nisi et iaculis. Donec congue rutrum massa. Nulla congue augue non metus pharetra consectetur. Praesent sed tellus quis leo blandit sollicitudin. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos."

let li2 = "Pellentesque non iaculis purus. Maecenas laoreet feugiat massa in volutpat. Ut non nunc eleifend, tincidunt justo non, consequat ipsum. Ut quis nunc velit. Suspendisse consectetur turpis vel lectus faucibus semper et non elit. Etiam a fringilla lacus, nec scelerisque dui. Nulla quis orci tortor. Etiam nec scelerisque diam, sit amet blandit tellus. Nunc tortor nisi, volutpat id nibh et, ultrices molestie sem. Curabitur quis sem mi. Pellentesque odio eros, finibus luctus rutrum eu, consequat ut nulla. In et ipsum euismod, gravida augue quis, mattis nulla. Phasellus tristique accumsan justo sed dapibus. Pellentesque felis erat, tempus ac aliquam sed, interdum id mauris."

let li3 = "Aenean at mauris est. Etiam felis velit, tempor a ipsum quis, ornare ornare orci. Phasellus vehicula fermentum justo quis dictum. Sed sollicitudin quam augue, placerat gravida libero lacinia vitae. Vivamus lobortis mollis libero quis cursus. Vestibulum erat arcu, tincidunt ac lacus vel, luctus tincidunt magna. Duis rutrum at sapien et finibus. Proin lectus lacus, laoreet vitae auctor vitae, congue at nisi. Phasellus orci nisl, imperdiet ac magna eget, ornare dignissim sapien. Nullam ultricies dui ornare ante eleifend, at faucibus quam facilisis. Nulla tempus eros tincidunt porttitor hendrerit."

#Preview("Notes") {
    @Previewable @State var notes: [Note] = [
        Note(id: 0, content: li1, created: Date(), modified: Date()),
        Note(id: 1, content: li2, created: Date(), modified: Date()),
        Note(id: 2, content: li3, created: Date(), modified: Date()),
        Note(id: 3, content: li3, created: Date(), modified: Date()),
        Note(id: 4, content: li3, created: Date(), modified: Date()),
        Note(id: 5, content: li3, created: Date(), modified: Date()),
        Note(id: 6, content: li3, created: Date(), modified: Date()),
    ]
    FileList(notes: $notes, onSelect: {(n: Note) -> Void in print(n.id)}, onChange: {(q: String) -> Void in print(q)}, closeList: {() -> Void in print("closed")})
}
