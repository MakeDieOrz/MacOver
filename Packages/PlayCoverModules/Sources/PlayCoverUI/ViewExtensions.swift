//
//  ViewExtensions.swift
//  PlayCover
//

import SwiftUI

public extension View {
    func toastOverlay<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        self.safeAreaBar(edge: .bottom, content: content)
    }

    func toastBackground(glassPadding: CGFloat = 8) -> some View {
        self
            .padding()
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .containerRelative)
            .padding(glassPadding)
            .padding(.top)
    }
}
