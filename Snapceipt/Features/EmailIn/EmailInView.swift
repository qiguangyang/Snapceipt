import SwiftUI
import SwiftData
import Combine

/// The Email-in surface: an inbox-address card (copy / share) above a
/// failed-first list of email_in transactions. Tapping a row opens the review editor.
struct EmailInView: View {
    @State private var vm: EmailInViewModel
    @State private var shareItem: String?
    @State private var showPaywall = false
    let onClose: () -> Void
    let onReview: (String) -> Void
    /// Pulls the latest data from the server (a full SyncEngine.sync()). Used by pull-to-refresh
    /// and on appear so a server-created email-in receipt shows without waiting for a push.
    let onRefresh: () async -> Void
    @Environment(\.accent) private var accent
    @Environment(EntitlementStore.self) private var entitlement
    @Environment(ToastCenter.self) private var toasts

    init(context: ModelContext, sync: any SyncEnqueuing, api: any APIClient,
         userId: String, profileId: String,
         onClose: @escaping () -> Void, onReview: @escaping (String) -> Void,
         onRefresh: @escaping () async -> Void = {}) {
        _vm = State(initialValue: EmailInViewModel(context: context, sync: sync, api: api,
                                                   userId: userId, profileId: profileId))
        self.onClose = onClose
        self.onReview = onReview
        self.onRefresh = onRefresh
    }

    var body: some View {
        VStack(spacing: 0) {
            LbHeader(title: "Email-in receipts", onClose: onClose, onAdd: {}, showsAdd: false)
            ScrollView {
                VStack(spacing: 14) {
                    // `proRequired` (server 403) overrides the local entitlement: the server is the
                    // source of truth for this Pro-gated feature, so a not-Pro-server account sees
                    // the upgrade/restore card rather than an address card that 403s.
                    if entitlement.isPro && !vm.proRequired {
                        addressCard
                        if vm.inbox.isEmpty {
                            emptyState
                        } else {
                            ForEach(vm.inbox, id: \.id) { txn in
                                row(txn)
                            }
                        }
                    } else {
                        upgradeCard
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 40)
            }
            .refreshable { await onRefresh() }   // pull-to-refresh → full sync → list reloads
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.cream)
        .accessibilityIdentifier(AccessibilityID.emailInScreen)
        .task {
            await vm.loadAddressIfPro(isPro: entitlement.isPro)
            // Pull fresh data on open so a server-created receipt appears without a push. Free users
            // see the in-page upgrade card (no auto-popped paywall) — they tap it to subscribe.
            if entitlement.isPro { await onRefresh() }
        }
        // Subscribing via the in-page upgrade card flips isPro → load the address + pull the inbox
        // so the page updates in place without re-opening.
        .onChange(of: entitlement.isPro) { wasPro, isPro in
            if isPro && !wasPro {
                Task { await vm.loadAddress(); await onRefresh() }
            }
        }
        // A push-triggered sync just pulled a new email-in receipt — re-fetch the inbox so it
        // appears while the screen is open (the list is a manual fetch, not a @Query).
        .onReceive(NotificationCenter.default.publisher(for: .emailInReceiptArrived)) { _ in
            vm.reload()
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
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
                // Copy / Share act on the address — only show them once it has loaded, so
                // the error state isn't a row of dead buttons.
                if let addr = vm.address?.address {
                    HStack(spacing: 10) {
                        actionChip("Copy", "doc.on.doc", id: AccessibilityID.emailInCopy) {
                            UIPasteboard.general.string = addr
                            toasts.show("Address copied", kind: .success)
                        }
                        actionChip("Share", "square.and.arrow.up", id: nil) { shareItem = addr }
                    }
                }
            }
        }
    }

    /// Free users see a clean Pro-upgrade surface instead of an address card that
    /// would 403. Email-in is Pro-only (server enforces it); this just mirrors that.
    private var upgradeCard: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                IconCircle(name: "receipt", tint: accent.base, soft: accent.soft, size: 44, iconSize: 22)
                Text("Email-in is a Pro feature")
                    .font(.ui(17, .semibold)).foregroundStyle(Palette.ink)
                Text("Get a private inbox address and forward receipts straight into Snapceipt — we'll extract them for you.")
                    .font(.ui(13.5)).foregroundStyle(Palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showPaywall = true } label: {
                    Text("Upgrade to Pro")
                        .font(.ui(15, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.emailInUpgrade)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        Button {
            guard entitlement.isPro else { showPaywall = true; return }
            onReview(txn.id)
        } label: {
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
            // Make the WHOLE card (incl. the empty Spacer between the merchant and the
            // trailing badge/amount, plus the card's own padding) a single hit target,
            // so a tap anywhere on the row opens the review editor. Without this the
            // Spacer leaves an un-hittable gap and the row reads as "not hittable".
            .contentShape(Rectangle())
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
