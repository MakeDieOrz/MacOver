//
//  GlassToastStack.swift
//  PlayCover
//

import SwiftUI

struct GlassToastStack: View {
    @Environment(ToastVM.self) var toastVM

    private var visibleToasts: [ToastInfo] {
        Array(toastVM.toasts.suffix(3))
    }

    var body: some View {
        if toastVM.isShown && !visibleToasts.isEmpty {
            VStack(spacing: 8) {
                ForEach(visibleToasts) { toast in
                    GlassToastCapsule(toast: toast) {
                        withAnimation(.snappy) {
                            toastVM.dismiss(id: toast.id)
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        let seconds = max(toast.timeRemaining, 4)
                        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.snappy) {
                            toastVM.dismiss(id: toast.id)
                        }
                    }
                }
            }
            .frame(maxWidth: 460)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .animation(.snappy, value: visibleToasts)
        }
    }
}

private struct GlassToastCapsule: View {
    let toast: ToastInfo
    let onDismiss: () -> Void

    private var iconName: String {
        switch toast.toastType {
        case .notice: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .network: return "network"
        }
    }

    private var tintColor: Color {
        switch toast.toastType {
        case .notice: return .accentColor
        case .error: return .orange
        case .network: return .blue
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(tintColor)
                .accessibilityHidden(true)

            Text(toast.toastDetails)
                .font(.callout)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("button.Dismiss")
            .accessibilityLabel(Text("button.Dismiss"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: 460)
        .contentShape(Capsule())
        .onTapGesture(perform: onDismiss)
        .glassEffect(.regular.interactive(), in: .capsule)
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(toast.toastDetails))
        .accessibilityAction(named: Text("button.Dismiss"), onDismiss)
    }
}
