import SwiftUI
import Observation

enum ToastKind { case info, success, error }
struct ToastItem: Identifiable, Equatable { let id = UUID(); let message: String; let kind: ToastKind }

@Observable final class ToastCenter {
    private(set) var current: ToastItem?
    func show(_ message: String, kind: ToastKind = .info) { current = ToastItem(message: message, kind: kind) }
    func clear() { current = nil }
}

struct ToastHost: ViewModifier {
    @Bindable var center: ToastCenter
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = center.current {
                HStack(spacing: 6) {
                    if t.kind == .success {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.income)
                    } else if t.kind == .error {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.white)
                    }
                    Text(t.message).font(.ui(13.5, .semibold)).foregroundStyle(.white)
                }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(t.kind == .error ? Palette.alert : Palette.ink, in: Capsule())
                    .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(2.5)); center.clear() }
            }
        }
    }
}
extension View { func toastHost(_ center: ToastCenter) -> some View { modifier(ToastHost(center: center)) } }
