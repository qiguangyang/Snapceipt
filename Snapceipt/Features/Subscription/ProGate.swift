import Foundation

/// Pure, testable decision for whether a Pro-only feature is unlocked.
/// Pro features (site/public/pricing.html): BAS-ready export, quotes & invoices,
/// vehicle & WFH logbooks, email-in. Mirrors the static-gate idiom used by
/// `ReportsView.showsBasCard`. Fails CLOSED: any non-"pro" plan locks everything.
struct ProGate {
    enum Feature { case basExport, quotes, logbooks, emailIn }

    let isPro: Bool

    init(plan: String?) {
        self.isPro = (plan == "pro")
    }

    func allows(_ feature: Feature) -> Bool { isPro }
}
