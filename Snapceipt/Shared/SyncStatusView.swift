import SwiftUI

/// A compact status pill reflecting the `SyncEngine` state. Hidden when idle so the
/// shell stays calm; visible (with copy + tint) while syncing / offline / errored.
struct SyncStatusView: View {
    let status: SyncStatus

    var body: some View {
        // The pill view ALWAYS exists (even when idle, where it has no visible
        // content) so XCUITest can read its a11y value across a sync drain. Its
        // a11y VALUE carries the raw state token (idle/syncing/offline/error).
        Group {
            if let model = display {
                HStack(spacing: 6) {
                    if model.spinning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(model.tint)
                    } else {
                        Circle().fill(model.tint).frame(width: 7, height: 7)
                    }
                    Text(model.label)
                        .font(.ui(11.5, .semibold))
                        .foregroundStyle(Palette.ink2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Palette.paper)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
                .cardShadow()
            } else {
                // Idle: keep a zero-footprint element so the a11y node persists.
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(AccessibilityID.syncStatusPill)
        .accessibilityValue(stateToken)
    }

    /// Raw state token surfaced as the pill's a11y value, independent of the
    /// localized visible label, so test predicates match on stable strings.
    private var stateToken: String {
        switch status {
        case .idle:    return "idle"
        case .syncing: return "syncing"
        case .offline: return "offline"
        case .error:   return "error"
        }
    }

    private struct Display {
        let label: String
        let tint: Color
        let spinning: Bool
    }

    private var display: Display? {
        switch status {
        case .idle:
            return nil
        case .syncing:
            return Display(label: "Syncing…", tint: Palette.ink3, spinning: true)
        case .offline:
            return Display(label: "Offline", tint: Palette.ink3, spinning: false)
        case .error:
            return Display(label: "Sync failed", tint: Palette.alert, spinning: false)
        }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 12) {
        SyncStatusView(status: .syncing)
        SyncStatusView(status: .offline)
        SyncStatusView(status: .error("boom"))
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.cream)
}
#endif
