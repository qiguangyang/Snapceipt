import Foundation

/// Keyword -> CategoryKey map shared (by value) with src/lib/receiptCategory.ts.
/// Kept in sync via ReceiptCategoryHeuristicTests / extractionHeuristic.test.ts.
enum ReceiptCategoryHeuristic {
    private static let table: [(CategoryKey, [String])] = [
        (.groceries, ["woolworths", "coles", "aldi", "iga", "foodland", "costco", "supabarn"]),
        (.fuel, ["shell", "bp", "caltex", "ampol", "mobil", "7-eleven", "united petroleum"]),
        (.meals, ["cafe", "coffee", "restaurant", "bakery", "pizza", "mcdonald", "kfc", "subway", "nando", "grill", "kitchen", "eatery", "uber eats", "doordash", "menulog"]),
        (.travel, ["uber", "didi", "ola", "taxi", "qantas", "jetstar", "virgin australia", "rex", "hotel", "motel", "airbnb", "booking.com", "flight", "parking", "toll", "linkt"]),
        (.software, ["apple.com/bill", "google", "microsoft", "adobe", "github", "aws", "amazon web", "openai", "anthropic", "figma", "notion", "slack", "zoom", "atlassian", "xero", "canva"]),
        (.health, ["pharmacy", "chemist", "priceline", "dental", "medical", "clinic", "physio", "optical", "terry white"]),
        (.home, ["bunnings", "ikea", "harvey norman", "jb hi-fi", "the good guys", "kmart", "target", "spotlight", "mitre 10"]),
        (.office, ["officeworks", "staples", "australia post", "auspost"]),
    ]

    /// Returns the category whose keyword appears earliest in the merchant name.
    /// When the merchant contains keywords from multiple categories (e.g. "Shell
    /// Coles Express" has "shell" at 0 and "coles" at 6), the earliest-occurring
    /// keyword wins — matching the TypeScript receiptCategory.ts behaviour.
    /// If the merchant matches nothing, fall back to scanning line texts in table
    /// order (first matching category wins).
    static func infer(merchant: String, lineTexts: [String]) -> CategoryKey {
        let merchantLower = merchant.lowercased()
        // Find the keyword whose start index in the merchant is smallest.
        var bestCat: CategoryKey? = nil
        var bestIdx: String.Index? = nil
        for (cat, kws) in table {
            for kw in kws {
                if let range = merchantLower.range(of: kw) {
                    if bestIdx == nil || range.lowerBound < bestIdx! {
                        bestIdx = range.lowerBound
                        bestCat = cat
                    }
                }
            }
        }
        if let cat = bestCat { return cat }
        // No merchant match — scan line texts in table order.
        let linesHay = lineTexts.joined(separator: " \n ").lowercased()
        for (cat, kws) in table where kws.contains(where: { linesHay.contains($0) }) { return cat }
        return .office
    }
}
