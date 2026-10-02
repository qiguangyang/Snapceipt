import SwiftUI

/// Bottom-sheet export flow (spec §6). Format tiles (PDF default / CSV / accountant),
/// a detail card scoped to the current Reports period, and a Generate & send CTA that
/// calls `POST /export`. pdf/csv -> share sheet on the returned URL; accountant ->
/// email the saved/edited accountant address (saved back on success). Presented as a
/// non-fullscreen Router `.export` overlay via the shell's `.sheet(item:)`.
struct ExportSheet: View {
    let api: APIClient
    let profileId: String
    let profileName: String
    /// The current Reports period range + label (spec §3.8: export inherits the period).
    let from: String
    let to: String
    let periodLabel: String
    let receiptsCount: Int
    let deductibleCents: Int
    /// Saved per-profile accountant email (prefill) + a persist-on-success callback.
    let savedAccountantEmail: String?
    let onSaveAccountantEmail: (String) -> Void
    let onClose: () -> Void
    /// When true (launched from BasView), the format is hard-pinned to `bas`: the
    /// tiles are hidden and Generate calls exportBas (spec §4.7). Default false.
    var basPinned: Bool = false
    var paygInstalmentCents: Int = 0

    @Environment(\.accent) private var accent

    private enum Format: String { case pdf, csv, accountant }
    private enum Phase: Equatable { case idle, inProgress, error(String) }

    @State private var format: Format = .pdf
    @State private var email: String = ""
    @State private var phase: Phase = .idle
    @State private var shareURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    if !basPinned { formatTiles }
                    detailCard
                    if format == .accountant && !basPinned { emailField }
                    cta
                    statusLine
                }
                .padding(18)
            }
        }
        // Add a "hide keyboard" accessory above the keyboard for the accountant email field.
        .keyboardDismissButton()
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.cream)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.exportSheet)
        .onAppear { email = savedAccountantEmail ?? "" }
        .sheet(item: shareItem) { item in ActivityView(url: item.url) }
    }

    private var header: some View {
        // The grabber is intentionally omitted here: the sheet is presented via the
        // shell's system .sheet(item:) with .presentationDragIndicator(.visible), which
        // already draws it (adding one would double the handle).
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Export").font(.display(22)).foregroundStyle(Palette.ink)
                Spacer()
                Button { onClose() } label: {
                    Icon(name: "close", size: 18, color: Palette.ink2)
                }.buttonStyle(.plain)
            }
            Text("Tax-ready summary with all receipts attached.")
                .font(.ui(13.5)).foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 6)
    }

    private var formatTiles: some View {
        HStack(spacing: 10) {
            tile(.pdf, title: "PDF report", icon: "receipt", id: AccessibilityID.exportFormatPDF)
            tile(.csv, title: "CSV file", icon: "chart", id: AccessibilityID.exportFormatCSV)
            tile(.accountant, title: "To accountant", icon: "bell", id: AccessibilityID.exportFormatAccountant)
        }
    }

    private func tile(_ f: Format, title: String, icon: String, id: String) -> some View {
        let selected = format == f
        return Button { format = f } label: {
            VStack(spacing: 8) {
                IconCircle(name: icon, tint: accent.base, soft: accent.soft, size: 38, iconSize: 19)
                Text(title).font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(selected ? accent.base : Palette.line2, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private var detailCard: some View {
        Card {
            VStack(spacing: 10) {
                detailRow("Period", periodLabel)
                detailRow("Receipts included", "\(receiptsCount)")
                detailRow("Deductible total", fmt(deductibleCents))
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.ui(13.5)).foregroundStyle(Palette.ink2)
            Spacer()
            Text(value).font(.ui(14, .semibold)).foregroundStyle(Palette.ink).monospacedDigit()
        }
    }

    private var emailField: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Accountant email").font(.ui(12.5, .semibold)).foregroundStyle(Palette.ink2)
                TextField("name@firm.com.au", text: $email)
                    .font(.ui(15)).foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .accessibilityIdentifier(AccessibilityID.exportEmailField)
            }
        }
    }

    /// True while generating, or when "To accountant" is selected with no email yet.
    private var ctaDisabled: Bool {
        phase == .inProgress || (format == .accountant && email.isEmpty)
    }

    private var cta: some View {
        Button { Task { await generate() } } label: {
            HStack {
                if phase == .inProgress { ProgressView().tint(.white) }
                Text(ctaTitle).font(.ui(15.5, .semibold)).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(accent.base, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            // Dim when unavailable so the disabled state is visible (the awaiting-email
            // case otherwise looks tappable but does nothing).
            .opacity(ctaDisabled ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(ctaDisabled)
        .animation(.easeOut(duration: 0.18), value: ctaDisabled)
        .accessibilityIdentifier(AccessibilityID.exportGenerate)
    }

    private var ctaTitle: String { format == .accountant ? "Generate & send" : "Generate" }

    @ViewBuilder private var statusLine: some View {
        if case let .error(message) = phase {
            Text(message).font(.ui(13)).foregroundStyle(Palette.alert)
                .accessibilityIdentifier(AccessibilityID.exportStatus)
        }
    }

    private func generate() async {
        phase = .inProgress
        do {
            if basPinned {
                let result = try await api.exportBas(profileId: profileId, from: from, to: to,
                                                     paygInstalmentCents: paygInstalmentCents, toEmail: nil)
                if case let .basPack(url, _, _, _, _) = result {
                    let full = url.hasPrefix("http") ? url : "\(BackendConfig.configuredBaseURL.absoluteString)\(url)"
                    shareURL = URL(string: full)
                }
                phase = .idle
                return
            }
            let result = try await api.export(profileId: profileId, format: format.rawValue,
                                               from: from, to: to,
                                               toEmail: format == .accountant ? email : nil)
            switch result {
            case let .download(url, _):
                // Resolve a shareable URL (absolute or app-host-relative).
                let full = url.hasPrefix("http") ? url : "\(BackendConfig.configuredBaseURL.absoluteString)\(url)"
                shareURL = URL(string: full)
                phase = .idle
            case .sent:
                onSaveAccountantEmail(email)
                phase = .idle
                onClose()
            case .basPack:
                phase = .idle   // unreachable via the non-pinned export()
            }
        } catch let e as APIError {
            phase = .error(e.message)
        } catch {
            phase = .error("Export failed. Try again.")
        }
    }

    /// Identifiable wrapper so `.sheet(item:)` presents the share sheet for a URL.
    private struct ShareItem: Identifiable { let id = UUID(); let url: URL }
    private var shareItem: Binding<ShareItem?> {
        Binding(get: { shareURL.map { ShareItem(url: $0) } },
                set: { if $0 == nil { shareURL = nil } })
    }
}

/// UIActivityViewController bridge for the export share sheet.
private struct ActivityView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
