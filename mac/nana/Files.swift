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

    @Environment(\.dismiss) private var dismiss // For macOS 12+
    @State private var query: String = "eve"
    @Environment(\.colorScheme) var colorScheme
    //@State private var colorScheme: ColorScheme = .dark
    @State var hoverClose = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack() {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundColor(colorC(colorScheme: colorScheme))
                TextField(
                    "Query",
                    text: $query
                )
                .font(.system(size: 20))
                .foregroundStyle(colorA(colorScheme: colorScheme))
                .textFieldStyle(.plain)
                Spacer()
                Button(action: {dismiss()}){
                    ZStack {
                        Circle()
                            .fill(colorB(colorScheme: colorScheme))
                            .frame(width:25, height:25)
                        Image(systemName: "xmark")
                            .font(.system(size: 20))
                            .foregroundColor(colorC(colorScheme: colorScheme).mix(with: .black, by: hoverClose ? 0.2 : 0.0))
                    }
                }.buttonStyle(PlainButtonStyle())
                    .onHover{ _ in
                        self.hoverClose.toggle()
                    }
            }
            .padding()
            //.border(.white)
            
            Divider()
                .background(colorC(colorScheme: colorScheme))
            List(notes, id: \.id) { note in
                HStack(){
                    Text(note.content)
                        .lineLimit(3)
                        .foregroundStyle(colorA(colorScheme: colorScheme))
                    Spacer()
                    VStack(){
                        Text(Date.now.formatted(date: .long, time: .omitted))
                            .foregroundStyle(colorC(colorScheme: colorScheme))
                            .italic()
                        Spacer()
                    }
                }
                .listRowSeparatorTint(colorC(colorScheme: colorScheme))
                .onTapGesture {
                    onSelect(note)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .scrollIndicators(.never)
            //.border(.white)
        }
        .background(colorB(colorScheme: colorScheme))
        .frame(minHeight: 200)
    }
}


let li1 = "Donec interdum turpis non ipsum venenatis porttitor. Sed malesuada tempor ultricies. Morbi at elit elit. Proin id ligula consequat ipsum mollis pharetra. Praesent in tempor purus. Aenean sapien risus, maximus id elit ac, ullamcorper sollicitudin eros. Nulla blandit nec nisi et iaculis. Donec congue rutrum massa. Nulla congue augue non metus pharetra consectetur. Praesent sed tellus quis leo blandit sollicitudin. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos."

let li2 = "Pellentesque non iaculis purus. Maecenas laoreet feugiat massa in volutpat. Ut non nunc eleifend, tincidunt justo non, consequat ipsum. Ut quis nunc velit. Suspendisse consectetur turpis vel lectus faucibus semper et non elit. Etiam a fringilla lacus, nec scelerisque dui. Nulla quis orci tortor. Etiam nec scelerisque diam, sit amet blandit tellus. Nunc tortor nisi, volutpat id nibh et, ultrices molestie sem. Curabitur quis sem mi. Pellentesque odio eros, finibus luctus rutrum eu, consequat ut nulla. In et ipsum euismod, gravida augue quis, mattis nulla. Phasellus tristique accumsan justo sed dapibus. Pellentesque felis erat, tempus ac aliquam sed, interdum id mauris."

let li3 = "Aenean at mauris est. Etiam felis velit, tempor a ipsum quis, ornare ornare orci. Phasellus vehicula fermentum justo quis dictum. Sed sollicitudin quam augue, placerat gravida libero lacinia vitae. Vivamus lobortis mollis libero quis cursus. Vestibulum erat arcu, tincidunt ac lacus vel, luctus tincidunt magna. Duis rutrum at sapien et finibus. Proin lectus lacus, laoreet vitae auctor vitae, congue at nisi. Phasellus orci nisl, imperdiet ac magna eget, ornare dignissim sapien. Nullam ultricies dui ornare ante eleifend, at faucibus quam facilisis. Nulla tempus eros tincidunt porttitor hendrerit."

#Preview("Notes") {
    @State var notes: [Note] = [
        Note(id: 0, content: li1, created: Date(), modified: Date()),
        Note(id: 1, content: li2, created: Date(), modified: Date()),
        Note(id: 2, content: li3, created: Date(), modified: Date()),
        Note(id: 3, content: li3, created: Date(), modified: Date()),
        Note(id: 4, content: li3, created: Date(), modified: Date()),
        Note(id: 5, content: li3, created: Date(), modified: Date()),
        Note(id: 6, content: li3, created: Date(), modified: Date()),
    ]
    FileList(notes: $notes, onSelect: {(n: Note) -> Void in print(n.id)})
}
