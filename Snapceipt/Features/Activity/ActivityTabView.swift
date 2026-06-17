import SwiftUI
import SwiftData

/// The Activity tab — a list of the active profile's saved receipts, newest first.
/// Reloads on appear so a receipt scanned-and-saved a moment ago shows immediately.
struct ActivityTabView: View {
    let context: ModelContext
    let profileId: String
    @Environment(\.accent) private var accent
    @State private var vm: ReceiptsListViewModel?

    var body: some View {
        ZStack {
            Palette.cream.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let rows = vm?.rows, !rows.isEmpty {
                    list(rows)
                } else {
                    Spacer(); emptyState; Spacer()
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.activityScreen)
        // New VM on appear / profile switch → fresh fetch (picks up a just-saved receipt).
        .task(id: profileId) {
            vm = ReceiptsListViewModel(context: context, profileId: profileId)
        }
    }

    private var header: some View {
        HStack {
            Text("Activity").font(.ui(26, .bold)).foregroundStyle(Palette.ink)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
    }

    private func list(_ rows: [ReceiptRow]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(rows) { receiptRow($0) }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
        }
    }

    @ViewBuilder private func receiptRow(_ row: ReceiptRow) -> some View {
        ReceiptRowView(row: row)
            .accessibilityIdentifier(AccessibilityID.activityRowPrefix + row.id)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            IconCircle(name: "receipt", tint: accent.base, soft: accent.soft, size: 64, iconSize: 30)
            Text("No receipts yet").font(.ui(17, .semibold)).foregroundStyle(Palette.ink)
            Text("Tap Snap to scan your first receipt — it'll appear here.")
                .font(.ui(13)).foregroundStyle(Palette.ink3).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .accessibilityIdentifier(AccessibilityID.activityEmpty)
    }
}
