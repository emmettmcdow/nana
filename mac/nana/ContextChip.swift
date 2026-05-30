//
//  ContextChip.swift
//  nana
//

import SwiftUI

struct ContextChip: View {
    @ObservedObject var contextManager: ContextManager
    var onSwitch: (WorkspaceContext) -> Void
    var onAddNew: () -> Void

    @State private var hover = false
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        let activeID = contextManager.activeID
        let name = contextManager.activeContext?.displayName ?? "No Context"

        Menu {
            ForEach(contextManager.contexts) { ctx in
                Button {
                    guard ctx.id != activeID else { return }
                    onSwitch(ctx)
                } label: {
                    if ctx.id == activeID {
                        Label(ctx.displayName, systemImage: "checkmark")
                    } else {
                        Text(ctx.displayName)
                    }
                }
            }
            Divider()
            Button {
                onAddNew()
            } label: {
                Label("Add new...", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.foreground)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hover ? palette.background.mix(with: palette.foreground, by: 0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

#Preview {
    ContextChip(
        contextManager: ContextManager(),
        onSwitch: { _ in },
        onAddNew: {}
    )
    .padding()
    .frame(width: 300, height: 60)
}
