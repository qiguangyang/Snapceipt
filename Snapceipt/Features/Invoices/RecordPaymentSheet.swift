import SwiftUI
import SwiftData
import Observation

/// Records a payment against an issued invoice (spec §4.4). Amount defaults to the
/// outstanding balance; on save inserts a `Payment` row + enqueues a sync upsert.
@Observable
@MainActor
final class RecordPaymentViewModel {
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let sync: any SyncEnqueuing
    @ObservationIgnored private let userId: String
    @ObservationIgnored private let invoiceId: String

    var amountCents: Int
    var paidOn: String
    var method: String?
    var note: String?

    private(set) var totalCents: Int = 0
    private(set) var paidCents: Int = 0

    init(context: ModelContext, sync: any SyncEnqueuing, userId: String, invoiceId: String) {
        self.context = context
        self.sync = sync
        self.userId = userId
        self.invoiceId = invoiceId
        self.paidOn = ExportDateFormatter.shared.string(from: Date())
        self.amountCents = 0

        let id = invoiceId
        var d = FetchDescriptor<Invoice>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        totalCents = (try? context.fetch(d))?.first?.totalCents ?? 0

        let pd = FetchDescriptor<Payment>(predicate: #Predicate { $0.invoiceId == id && $0.deletedAt == nil })
        let amounts = ((try? context.fetch(pd)) ?? []).map { AccountsReceivable.PaymentAmount(amountCents: $0.amountCents) }
        paidCents = AccountsReceivable.amountPaidCents(amounts)
        amountCents = max(0, totalCents - paidCents)
    }

    var outstandingCents: Int { max(0, totalCents - paidCents) }
    var canSave: Bool { amountCents > 0 }

    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        let pay = Payment(userId: userId, invoiceId: invoiceId, amountCents: amountCents,
                          paidOn: paidOn, method: method, note: note)
        context.insert(pay)
        try? context.save()
        sync.enqueue(op: "upsert", entityType: .payment, entity: pay)
        return true
    }
}

/// Bottom sheet to record a payment. Amount in whole dollars (cents = ×100), defaulting
/// to the outstanding balance.
struct RecordPaymentSheet: View {
    let context: ModelContext
    let sync: any SyncEnqueuing
    let userId: String
    let invoiceId: String
    let onClose: () -> Void

    @Environment(\.accent) private var accent
    @State private var vm: RecordPaymentViewModel?

    private func fmt(_ cents: Int) -> String { "$\(cents / 100)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Record payment").font(.display(20, .bold)).foregroundStyle(Palette.ink)
            if let vm {
                Text("Outstanding \(fmt(vm.outstandingCents))").font(.ui(13.5)).foregroundStyle(Palette.ink2)
                Card(padding: 14) {
                    HStack(spacing: 8) {
                        Text("Amount $").font(.ui(14.5, .semibold)).foregroundStyle(Palette.ink2)
                        TextField("0", text: Binding(
                            get: { String(vm.amountCents / 100) },
                            set: { vm.amountCents = (Int($0.filter(\.isNumber)) ?? 0) * 100 }))
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier(AccessibilityID.recordPaymentAmount)
                    }
                }
                Button {
                    if vm.save() { onClose() }
                } label: {
                    Text("Save payment").font(.ui(16, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(accent.base, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .opacity(vm.canSave ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!vm.canSave)
                .accessibilityIdentifier(AccessibilityID.recordPaymentSave)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cream)
        .accessibilityIdentifier(AccessibilityID.recordPaymentSheet)
        .task {
            if vm == nil {
                vm = RecordPaymentViewModel(context: context, sync: sync, userId: userId, invoiceId: invoiceId)
            }
        }
    }
}
