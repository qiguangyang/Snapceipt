import SwiftUI
import SwiftData

/// The Email-in surface: an inbox-address card (copy / share / rotate) above a
/// failed-first list of email_in transactions. Tapping a row opens the review editor.
struct EmailInView: View {
    @State private var vm: EmailInViewModel
    @State private var shareItem: String?
    let onClose: () -> Void
    let onReview: (String) -> Void
    @Environment(\.accent) private var accent

    init(context: ModelContext, sync: any SyncEnqueuing, api: any APIClient,
         userId: String, profileId: String,
         onClose: @escaping () -> Void, onReview: @escaping (String) -> Void) {
        _vm = State(initialValue: EmailInViewModel(context: context, sync: sync, api: api,
                                                   userId: userId, profileId: profileId))
        self.onClose = onClose
        self.onReview = onReview
    }

    var body: some View {
        VStack(spacing: 0) {
            LbHeader(title: "Email-in receipts", onClose: onClose, onAdd: {}, showsAdd: false)
            ScrollView {
                VStack(spacing: 14) {
                    addressCard
                    if vm.inbox.isEmpty {
                        emptyState
                    } else {
                        ForEach(vm.inbox, id: \.id) { txn in
                            row(txn)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .accessibilityIdentifier(AccessibilityID.emailInScreen)
        .task { await vm.loadAddress() }
        .sheet(item: shareBinding) { item in EmailInActivityView(text: item.text) }
    }

    private var addressCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Forward receipts to").font(.ui(13, .semibold)).foregroundStyle(Palette.ink3)
                Text(vm.address?.address ?? (vm.isLoadingAddress ? "Loading…" : "—"))
                    .font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
                    .textSelection(.enabled).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityID.emailInAddress)
                if let err = vm.errorMessage {
                    HStack(spacing: 10) {
                        Text(err).font(.ui(12.5)).foregroundStyle(Palette.alert)
                            .accessibilityIdentifier(AccessibilityID.emailInError)
                        if vm.address == nil {
                            Button("Retry") { Task { await vm.loadAddress() } }
                                .font(.ui(12.5, .semibold)).foregroundStyle(accent.base)
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(AccessibilityID.emailInRetry)
                        }
                    }
                }
                HStack(spacing: 10) {
                    actionChip("Copy", "doc.on.doc", id: AccessibilityID.emailInCopy) {
                        if let a = vm.address?.address { UIPasteboard.general.string = a }
                    }
                    actionChip("Share", "square.and.arrow.up", id: nil) {
                        shareItem = vm.address?.address
                    }
                    actionChip("Rotate", "arrow.triangle.2.circlepath", id: AccessibilityID.emailInRotate) {
                        Task { await vm.rotate() }
                    }
                }
            }
        }
    }

    private func actionChip(_ title: String, _ systemImage: String, id: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.ui(13, .semibold)).foregroundStyle(accent.base)
                .padding(.vertical, 8).padding(.horizontal, 12)
                .background(accent.soft, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id ?? "emailin.share")
    }

    private func row(_ txn: Transaction) -> some View {
        Button { onReview(txn.id) } label: {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    IconCircle(name: txn.extractionStatus == "failed" ? "info" : "receipt",
                               tint: accent.base, soft: accent.soft, size: 38, iconSize: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(txn.merchant.isEmpty ? "Untitled receipt" : txn.merchant)
                            .font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink)
                        Text(fmtDate(txn.txnDate)).font(.ui(12.5)).foregroundStyle(Palette.ink3)
                    }
                    Spacer()
                    if txn.extractionStatus == "failed" {
                        Text("Needs review").font(.ui(11.5, .semibold)).foregroundStyle(.white)
                            .padding(.vertical, 4).padding(.horizontal, 8)
                            .background(Palette.alert, in: Capsule())
                    } else {
                        Text(fmt(txn.amountCents))
                            .font(.ui(14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.emailInListRowPrefix + txn.id)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            EmptyArt(kind: .receipt, size: 120)
            Text("No emailed receipts yet").font(.ui(15, .semibold)).foregroundStyle(Palette.ink)
            Text("Forward a receipt to the address above and it'll show up here for review.")
                .font(.ui(13)).foregroundStyle(Palette.ink3).multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    /// Identifiable wrapper so `.sheet(item:)` presents the share sheet for the alias text.
    private struct ShareText: Identifiable { let id = UUID(); let text: String }
    private var shareBinding: Binding<ShareText?> {
        Binding(get: { shareItem.map { ShareText(text: $0) } },
                set: { if $0 == nil { shareItem = nil } })
    }
}

/// UIActivityViewController bridge for sharing the inbox alias text.
private struct EmailInActivityView: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
