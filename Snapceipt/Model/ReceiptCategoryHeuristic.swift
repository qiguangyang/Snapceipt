import Foundation

/// Keyword -> CategoryKey map shared (by value) with src/lib/receiptCategory.ts.
/// Kept in sync via the golden corpus in HeuristicParserTests / extractionHeuristic.test.ts.
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

    static func infer(merchant: String, lineTexts: [String]) -> CategoryKey {
        let hay = ([merchant] + lineTexts).joined(separator: " \n ").lowercased()
        for (cat, kws) in table where kws.contains(where: { hay.contains($0) }) { return cat }
        return .office
    }
}
