import SwiftUI

/// Observable state for the Share Extension popup. The host `ShareViewController` owns it,
/// drives the on-device extraction into it, and reads `image`/`draft` back on Save.
/// `ObservableObject` (not @Observable) so the popup runs on the extension's iOS 17 floor.
@MainActor
final class ShareReviewModel: ObservableObject {
    enum Phase: Equatable {
        case loading          // pulling the image/PDF out of the share item
        case reading          // OCR + on-device extraction in flight
        case ready            // extraction done (draft may be nil → empty fields)
        case saving
        case saved
    }

    @Published var phase: Phase = .loading
    @Published var image: UIImage?
    /// The parsed draft, or nil when extraction was unavailable/failed (Save still works —
    /// it writes the JPEG only and the app re-extracts on open).
    @Published var draft: ExtractedReceipt?

    /// True once we have an image to show (even while still reading it).
    var hasImage: Bool { image != nil }

    var merchantText: String {
        let m = draft?.merchant.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return m.isEmpty ? "—" : m
    }

    var totalText: String {
        guard let total = draft?.total, total > 0 else { return "—" }
        let code = draft?.currencyCode ?? "AUD"
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.locale = Locale(identifier: "en_AU")
        return f.string(from: total as NSDecimalNumber) ?? "\(total)"
    }

    /// "YYYY-MM-DD" reformatted to a friendly medium date; falls back to the raw string.
    var dateText: String {
        guard let raw = draft?.date, !raw.isEmpty else { return "—" }
        let parse = DateFormatter()
        parse.calendar = Calendar(identifier: .gregorian)
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(identifier: "UTC")
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: raw) else { return raw }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeZone = TimeZone(identifier: "UTC")
        out.locale = Locale(identifier: "en_AU")
        return out.string(from: d)
    }
}

/// The Share Extension popup: shows the shared receipt, reads it on-device, and offers
/// Save / Cancel. Plain SwiftUI (no app design system in the extension) — a card, system
/// fonts, a tinted primary button. Save/Cancel are delegated to the host view controller,
/// which owns the `extensionContext` and the App Group write.
struct ShareReviewView: View {
    @ObservedObject var model: ShareReviewModel
    var onSave: () -> Void
    var onCancel: () -> Void

    private let tint = Color(red: 0.055, green: 0.486, blue: 0.447)   // app teal (#0E7C72)

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 16) {
                        receiptCard
                        if model.phase == .reading || model.phase == .loading {
                            readingBanner
                        } else if model.phase == .saved {
                            savedBanner
                        } else {
                            fieldsCard
                        }
                    }
                    .padding(16)
                }
                footer
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Save to Snapceipt")
                .font(.headline)
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: Receipt image

    private var receiptCard: some View {
        Group {
            if let image = model.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 240)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
                    .frame(height: 200)
                    .overlay(ProgressView())
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(.separator), lineWidth: 0.5))
    }

    // MARK: States

    private var readingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Reading receipt…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var savedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
            Text("Saved to Snapceipt").fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var fieldsCard: some View {
        VStack(spacing: 0) {
            row(label: "Merchant", value: model.merchantText)
            Divider().padding(.leading, 16)
            row(label: "Total", value: model.totalText)
            Divider().padding(.leading, 16)
            row(label: "Date", value: model.dateText)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func row(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: onSave) {
                Text(saveTitle)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .background(saveEnabled ? tint : Color(.systemGray3))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(!saveEnabled)

            Button(action: onCancel) {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .foregroundStyle(.secondary)
            .disabled(model.phase == .saving || model.phase == .saved)
        }
        .padding(16)
        .background(.regularMaterial)
    }

    /// Save is enabled once we have an image (works even with no draft — JPEG-only fallback),
    /// and disabled while we're still loading the image or already saving/saved.
    private var saveEnabled: Bool {
        model.hasImage && model.phase != .loading && model.phase != .saving && model.phase != .saved
    }

    private var saveTitle: String {
        switch model.phase {
        case .saving: return "Saving…"
        case .saved:  return "Saved ✓"
        default:      return "Save to Snapceipt"
        }
    }
}
