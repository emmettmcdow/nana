//
//  Update.swift
//  nana
//
//  Created by Emmett McDow on 10/11/25.
//

import SwiftUI

struct Update: View {
    @AppStorage("colorSchemePreference") private var preference: ColorSchemePreference = .system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Palette.forPreference(preference, colorScheme: colorScheme)
        VStack {
            Spacer()
            HStack {
                LoadingBanana(msg: "updating")
                Spacer()
            }
        }
        .background(palette.background)
    }
}

#Preview {
    Update()
}
