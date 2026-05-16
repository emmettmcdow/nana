import SwiftUI

struct DebugOverlay: View {
    @ObservedObject var settings: DebugSettings

    var body: some View {
        TimelineView(.animation) { context in
            HStack(spacing: 10) {
                Text(String(format: "%.0f fps", settings.fps))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minWidth: 44, alignment: .trailing)

                Divider()
                    .frame(height: 12)

                Toggle(isOn: $settings.showBoundingBoxes) {
                    Text("Bounding Boxes")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                Divider()
                    .frame(height: 12)

                Toggle(isOn: $settings.hideMarkdownChars) {
                    Text("Hide MD Chars")
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)

                Spacer()

                Text("DEBUG \(BuildInfo.label)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.bar)
            .frame(maxWidth: .infinity)
            .onChange(of: context.date) { newDate in
                settings.tick(now: newDate)
            }
        }
    }
}
