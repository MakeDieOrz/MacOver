//
//  IPADropOverlay.swift
//  PlayCover
//

import SwiftUI

struct IPADropOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("ui51.library.dropTitle")
                    .font(.title2.bold())
                Text("ui51.library.dropSubtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
