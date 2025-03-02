//
//  ContentView.swift
//  nana
//
//  Created by Emmett McDow on 2/25/25.
//

import SwiftUI


let lightYellow = Color(red: 0.7607843137254902, green: 0.7137254901960784, blue: 0.5843137254901961)
let darkBrown = Color(red:0.14901960784313725, green: 0.1411764705882353, blue: 0.11372549019607843)

func colorA(colorScheme: ColorScheme) -> Color {
    return colorScheme == .light ? darkBrown : lightYellow
}

func colorB(colorScheme: ColorScheme) -> Color {
    return colorScheme == .dark ? darkBrown : lightYellow
}

func colorC(colorScheme: ColorScheme) -> Color {
    return .gray
}

struct CircularPlusButton: View {
    var action: () -> Void
    var colorScheme: ColorScheme = .light
    var size: CGFloat = 50
    @State var hover = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(colorA(colorScheme: colorScheme).mix(with: .black, by: hover ? 0.1 : 0.0))
                    .frame(width: size, height: size)
                    .shadow(radius: 2)
                    .tint(hover ? .green : .clear)
                
                Image(systemName: "plus")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(colorB(colorScheme: colorScheme))
            }
        }.buttonStyle(PlainButtonStyle())
            .onHover{ _ in
                self.hover.toggle()
                print(self.hover)
            }
            
    }
}

struct SearchButton: View {
    var colorScheme: ColorScheme = .light
    var size: CGFloat = 50
    @State var shouldPresentSheet = false
    @State var hover = false
    
    @State private var notes: [Note] = [
        Note(id: 0, created: Date(), modified: Date(), relpath: "/foo/bar", content: li1),
        Note(id: 1, created: Date(), modified: Date(), relpath: "/foo/bar2", content: li2),
        Note(id: 2, created: Date(), modified: Date(), relpath: "/foo/bar3", content: li3),
        Note(id: 3, created: Date(), modified: Date(), relpath: "/foo/bar4", content: li3),
        Note(id: 4, created: Date(), modified: Date(), relpath: "/foo/bar5", content: li3),
        Note(id: 5, created: Date(), modified: Date(), relpath: "/foo/bar6", content: li3),
        Note(id: 6, created: Date(), modified: Date(), relpath: "/foo/bar7", content: li3),
    ]
    
    var body: some View {
        Button (action: {shouldPresentSheet.toggle()}){
            ZStack() {
                Circle()
                    .fill(colorA(colorScheme: colorScheme).mix(with: .black, by: hover ? 0.1 : 0.0))

                    .frame(width: size, height: size)
                    .shadow(radius: 2)
                
                Image(systemName: "magnifyingglass")
                    .font(.system(size: size * 0.5))
                    .foregroundColor(colorB(colorScheme: colorScheme))
            }
        }
        .sheet(isPresented: $shouldPresentSheet) {
            FileList(notes: notes)
        }
        .interactiveDismissDisabled(false)
        .buttonStyle(PlainButtonStyle())
        .onHover{ _ in
            self.hover.toggle()
            print(self.hover)
        }
    }
}

struct ContentView: View {
    @State private var text: String = ""
    @Environment(\.colorScheme) var colorScheme
    //@State private var colorScheme: ColorScheme = .light
    
    var body: some View {
        ZStack() {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .foregroundColor(colorA(colorScheme: colorScheme))
                .accentColor(colorA(colorScheme: colorScheme))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(colorB(colorScheme: colorScheme))
            HStack() {
                Spacer()
                VStack() {
                    Spacer()
                    SearchButton(colorScheme: colorScheme)
                    CircularPlusButton(action: {
                        print("Button tapped!")
                    }, colorScheme: colorScheme)
                }
            }
        }
        .padding()
        .background(colorB(colorScheme: colorScheme))
    }
}

let li1 = "Donec interdum turpis non ipsum venenatis porttitor. Sed malesuada tempor ultricies. Morbi at elit elit. Proin id ligula consequat ipsum mollis pharetra. Praesent in tempor purus. Aenean sapien risus, maximus id elit ac, ullamcorper sollicitudin eros. Nulla blandit nec nisi et iaculis. Donec congue rutrum massa. Nulla congue augue non metus pharetra consectetur. Praesent sed tellus quis leo blandit sollicitudin. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos."

let li2 = "Pellentesque non iaculis purus. Maecenas laoreet feugiat massa in volutpat. Ut non nunc eleifend, tincidunt justo non, consequat ipsum. Ut quis nunc velit. Suspendisse consectetur turpis vel lectus faucibus semper et non elit. Etiam a fringilla lacus, nec scelerisque dui. Nulla quis orci tortor. Etiam nec scelerisque diam, sit amet blandit tellus. Nunc tortor nisi, volutpat id nibh et, ultrices molestie sem. Curabitur quis sem mi. Pellentesque odio eros, finibus luctus rutrum eu, consequat ut nulla. In et ipsum euismod, gravida augue quis, mattis nulla. Phasellus tristique accumsan justo sed dapibus. Pellentesque felis erat, tempus ac aliquam sed, interdum id mauris."

let li3 = "Aenean at mauris est. Etiam felis velit, tempor a ipsum quis, ornare ornare orci. Phasellus vehicula fermentum justo quis dictum. Sed sollicitudin quam augue, placerat gravida libero lacinia vitae. Vivamus lobortis mollis libero quis cursus. Vestibulum erat arcu, tincidunt ac lacus vel, luctus tincidunt magna. Duis rutrum at sapien et finibus. Proin lectus lacus, laoreet vitae auctor vitae, congue at nisi. Phasellus orci nisl, imperdiet ac magna eget, ornare dignissim sapien. Nullam ultricies dui ornare ante eleifend, at faucibus quam facilisis. Nulla tempus eros tincidunt porttitor hendrerit."

struct FileList: View {
    var notes: [Note]
    @Environment(\.dismiss) private var dismiss // For macOS 12+
    @State private var query: String = "eve"
    //@Environment(\.colorScheme) var colorScheme
    @State private var colorScheme: ColorScheme = .dark
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
                        print(self.hoverClose)
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
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            //.border(.white)
        }
        .background(colorB(colorScheme: colorScheme))
        .frame(minHeight: 200)
        .cornerRadius(15)
    }
}

#Preview("Editor") {
    ContentView()
}

#Preview("Notes") {
    var notes: [Note] = [
        Note(id: 0, created: Date(), modified: Date(), relpath: "/foo/bar", content: li1),
        Note(id: 1, created: Date(), modified: Date(), relpath: "/foo/bar2", content: li2),
        Note(id: 2, created: Date(), modified: Date(), relpath: "/foo/bar3", content: li3),
        Note(id: 3, created: Date(), modified: Date(), relpath: "/foo/bar4", content: li3),
        Note(id: 4, created: Date(), modified: Date(), relpath: "/foo/bar5", content: li3),
        Note(id: 5, created: Date(), modified: Date(), relpath: "/foo/bar6", content: li3),
        Note(id: 6, created: Date(), modified: Date(), relpath: "/foo/bar7", content: li3),
    ]
    FileList(notes: notes)
}

