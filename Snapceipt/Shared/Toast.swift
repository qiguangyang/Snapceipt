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
                // TODO(Task 2/3): swap to Font.ui(13.5, .semibold) + Palette.alert / Palette.ink
                // once the DesignSystem (Palette, Font.ui) lands. Using system equivalents now
                // so this file compiles standalone in the Task 1 scaffold.
                Text(t.message)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(t.kind == .error ? Color.red : Color.primary, in: Capsule())
                    .padding(.top, 8).transition(.move(edge: .top).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(2.5)); center.clear() }
            }
        }
    }
}
extension View { func toastHost(_ center: ToastCenter) -> some View { modifier(ToastHost(center: center)) } }
