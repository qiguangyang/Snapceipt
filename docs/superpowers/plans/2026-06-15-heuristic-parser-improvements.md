# Heuristic Parser Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the offline/capped receipt heuristic materially better and keep the Swift (`HeuristicParser.swift`, offline path) and TypeScript (`extractionHeuristic.ts`, **smart-scan-cap + DeepSeek-failure path**) parsers correct and in sync.

**Architecture:** Two deterministic, rule-based parsers turn OCR text into a draft receipt when the LLM isn't used. They have drifted; this plan brings both to parity on correctness (Tier 1), adds line-item + category inference + smarter merchant (Tier 2), grades confidence + uses OCR geometry on the Swift side (Tier 3), and locks them together with a shared golden-file corpus (Tier 4). The 9 category keys are identical across Swift `CategoryKey` and TS `CATEGORY_KEYS`, so a shared keyword→category map produces matching output.

**Tech Stack:** Swift / Swift Testing (`import Testing`); TypeScript / vitest + `@cloudflare/vitest-pool-workers`; Apple Vision `RecognizedLine` geometry.

**Why both parsers:** the **smart-scan-cap fallback and the DeepSeek-outage fallback both run the *server* parser** (`extractionHeuristic.ts`), while the truly-offline iOS path runs `HeuristicParser.swift`. Improving only Swift would leave capped users on the old server logic — so Tier 1/2 land in **both**, enforced by Tier 4's shared corpus. Geometry (Tier 3 #8) is iOS-only (the server only ever receives flattened text).

---

## Shared definitions used across tasks

**Category keyword map (identical in Swift + TS).** Case-insensitive substring match against the merchant first, then any line-item text. First category whose keyword matches wins; default `office` when nothing matches. `income` is never inferred from a receipt scan.

```
groceries : woolworths, coles, aldi, iga, foodland, costco, supabarn
fuel      : shell, bp, caltex, ampol, mobil, 7-eleven, united petroleum, ampol foodary
meals     : cafe, coffee, restaurant, bakery, bar, pizza, mcdonald, kfc, subway, nando, grill, kitchen, eatery, uber eats, doordash, menulog
travel    : uber, didi, ola, taxi, qantas, jetstar, virgin australia, rex, hotel, motel, airbnb, booking.com, flight, parking, toll, linkt
software  : apple.com/bill, google, microsoft, adobe, github, aws, amazon web, openai, anthropic, figma, notion, slack, zoom, atlassian, xero, canva
health    : pharmacy, chemist, chemist warehouse, priceline, dental, medical, clinic, physio, optical, terry white
home      : bunnings, ikea, harvey norman, jb hi-fi, the good guys, kmart, target, spotlight, mitre 10
office    : officeworks, staples, australia post, auspost   (also the DEFAULT)
```

**Tender / summary line keywords** (excluded from the total fallback and from line items): `total`, `subtotal`, `sub total`, `gst`, `tax`, `vat`, `change`, `cash`, `eftpos`, `balance`, `amount due`, `tendered`, `rounding`.

**Unified TOTAL algorithm (both parsers):**
1. Consider only lines that do NOT parse as a date.
2. If any line matches `total` as a whole word AND not `subtotal`/`sub total`: total = max cents-bearing amount on those lines.
3. Else: total = max cents-bearing amount among lines that are NOT tender/summary lines.
4. Clamp `>= 0`, round to cents.

**Graded confidence (both parsers, range 0.30–0.75):** start 0.30; +0.20 if an explicit "total" line was used; +0.10 if a date was parsed from the text (not the default); +0.10 if GST came from a printed line (not inferred); +0.05 if category came from a keyword match (not the default). `needsReview` stays `true` for any heuristic result.

---

## Task 1 — Shared category map + inference (TS first, it's the simpler host)

**Files:**
- Create: `src/lib/receiptCategory.ts`
- Test: `test/receiptCategory.test.ts`

- [ ] **Step 1: Write the failing test.** Create `test/receiptCategory.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { inferCategory } from "../src/lib/receiptCategory";

describe("inferCategory", () => {
  it("maps known merchants to their category (case-insensitive)", () => {
    expect(inferCategory("WOOLWORTHS 1234", [])).toBe("groceries");
    expect(inferCategory("Shell Coles Express", [])).toBe("fuel");
    expect(inferCategory("The Coffee Club", [])).toBe("meals");
    expect(inferCategory("Uber *Trip", [])).toBe("travel");
    expect(inferCategory("OFFICEWORKS", [])).toBe("office");
    expect(inferCategory("Chemist Warehouse", [])).toBe("health");
    expect(inferCategory("Bunnings Warehouse", [])).toBe("home");
    expect(inferCategory("ADOBE", [])).toBe("software");
  });
  it("falls back to a line item when the merchant is unknown", () => {
    expect(inferCategory("Unknown Store", ["Flat White", "Bacon roll"])).toBe("office"); // no kw -> default
    expect(inferCategory("Suncorp", ["Parking 1hr"])).toBe("travel");
  });
  it("defaults to office when nothing matches", () => {
    expect(inferCategory("Zzzqqq Pty Ltd", [])).toBe("office");
  });
});
```

- [ ] **Step 2: Run it — fails** (module missing): `npx vitest run test/receiptCategory.test.ts` → FAIL "Cannot find module".

- [ ] **Step 3: Implement.** Create `src/lib/receiptCategory.ts`:

```ts
// Keyword -> category map shared by the heuristic parsers (offline/capped path).
// Keys MUST match src/schemas/extract.ts CATEGORY_KEYS + iOS CategoryKey.
// `income` is intentionally never inferred from a receipt scan.
const CATEGORY_KEYWORDS: Array<[string, string[]]> = [
  ["groceries", ["woolworths", "coles", "aldi", "iga", "foodland", "costco", "supabarn"]],
  ["fuel", ["shell", "bp", "caltex", "ampol", "mobil", "7-eleven", "united petroleum"]],
  ["meals", ["cafe", "coffee", "restaurant", "bakery", "pizza", "mcdonald", "kfc", "subway", "nando", "grill", "kitchen", "eatery", "uber eats", "doordash", "menulog"]],
  ["travel", ["uber", "didi", "ola", "taxi", "qantas", "jetstar", "virgin australia", "rex", "hotel", "motel", "airbnb", "booking.com", "flight", "parking", "toll", "linkt"]],
  ["software", ["apple.com/bill", "google", "microsoft", "adobe", "github", "aws", "amazon web", "openai", "anthropic", "figma", "notion", "slack", "zoom", "atlassian", "xero", "canva"]],
  ["health", ["pharmacy", "chemist", "priceline", "dental", "medical", "clinic", "physio", "optical", "terry white"]],
  ["home", ["bunnings", "ikea", "harvey norman", "jb hi-fi", "the good guys", "kmart", "target", "spotlight", "mitre 10"]],
  ["office", ["officeworks", "staples", "australia post", "auspost"]],
];

/** First category whose keyword appears in the merchant (then any line text); else "office". */
export function inferCategory(merchant: string, lineTexts: string[]): string {
  const hay = [merchant, ...lineTexts].join(" \n ").toLowerCase();
  for (const [cat, kws] of CATEGORY_KEYWORDS) {
    if (kws.some((kw) => hay.includes(kw))) return cat;
  }
  return "office";
}
```

- [ ] **Step 4: Run it — passes:** `npx vitest run test/receiptCategory.test.ts` → PASS (all cases).

- [ ] **Step 5: Commit.**
```bash
git add src/lib/receiptCategory.ts test/receiptCategory.test.ts
git commit -m "$(cat <<'EOF'
feat(heuristic): shared keyword->category map for offline/capped extraction

Maps common AU merchants to the 9 CategoryKey values so the heuristic
(server cap/outage path) stops defaulting everything to "office".

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2 — Server parser (extractionHeuristic.ts): Tier-1 total fix + category + confidence

**Files:**
- Modify: `src/lib/extractionHeuristic.ts`
- Test: `test/extractionHeuristic.test.ts`

Read the current file first (it already skips date lines for the total and uses `\b(gst|tax)\b`). The gaps to close: (a) it picks the largest cents amount with NO preference for an explicit "total" line and NO exclusion of tender lines (so `CASH 50.00` beats `TOTAL 42.50`); (b) `category` is hardcoded `"office"`; (c) no graded confidence (the route hardcodes 0.3 on the capped path).

- [ ] **Step 1: Write failing tests.** Add to `test/extractionHeuristic.test.ts`:

```ts
it("prefers an explicit TOTAL line over a larger CASH tendered line", () => {
  const r = heuristicExtract("Cafe Norm\nFlat White 4.50\nTOTAL 4.50\nCASH 50.00\nCHANGE 45.50", "2026-06-15");
  expect(r.total).toBe(4.5);
});
it("ignores tender lines when no explicit total is present", () => {
  const r = heuristicExtract("Shop\nItem 9.00\nCASH 50.00\nCHANGE 41.00", "2026-06-15");
  expect(r.total).toBe(9); // largest non-tender cents amount
});
it("infers category from the merchant", () => {
  expect(heuristicExtract("WOOLWORTHS 123\nTOTAL 12.00", "2026-06-15").category).toBe("groceries");
  expect(heuristicExtract("Shell Express\nTOTAL 80.00", "2026-06-15").category).toBe("fuel");
});
it("grades confidence: total line + printed gst + known merchant", () => {
  const r = heuristicExtract("WOOLWORTHS\nTOTAL 11.00\nGST 1.00\non 15/06/2026", "2026-06-15");
  expect(r.confidence).toBeGreaterThanOrEqual(0.6);
  expect(r.needsReview).toBe(true);
});
```

- [ ] **Step 2: Run — fails** (`category` typed `"office"` literal won't widen, total/confidence assertions fail): `npx vitest run test/extractionHeuristic.test.ts` → FAIL.

- [ ] **Step 3: Implement.** In `src/lib/extractionHeuristic.ts`:
  1. Change the `HeuristicReceipt` interface: `category: string` (was the literal `"office"`); add `confidence: number;` and `needsReview: boolean;`.
  2. Import the map: `import { inferCategory } from "./receiptCategory";`.
  3. Add a tender/summary matcher and rewrite the total selection per the **Unified TOTAL algorithm** above:

```ts
const TENDER_RE = /\b(total|subtotal|sub total|gst|tax|vat|change|cash|eftpos|balance|amount\s*due|tendered|rounding)\b/i;
const TOTAL_RE = /\btotal\b/i;
const SUBTOTAL_RE = /\bsub\s?total\b/i;

function selectTotal(rawLines: string[]): { total: number; usedTotalLine: boolean } {
  const nonDate = rawLines.filter((l) => parseDate(l) === null);
  const totalLines = nonDate.filter((l) => TOTAL_RE.test(l) && !SUBTOTAL_RE.test(l));
  const pickMax = (lines: string[]) =>
    lines.reduce((mx, l) => { const a = centsAmountIn(l); return a !== null && a > mx ? a : mx; }, 0);
  if (totalLines.length) return { total: roundCents(Math.max(0, pickMax(totalLines))), usedTotalLine: true };
  const nonTender = nonDate.filter((l) => !TENDER_RE.test(l));
  return { total: roundCents(Math.max(0, pickMax(nonTender))), usedTotalLine: false };
}
```
  4. In `heuristicExtract`, replace the inline total loop with `const { total, usedTotalLine } = selectTotal(rawLines);`. Track `dateParsed` (whether a date came from the text) and `gstPrinted` (whether the GST came from a printed line).
  5. Compute category + confidence and return them:

```ts
  const category = inferCategory(merchant, lineItems.map((li) => li.name));
  let confidence = 0.3;
  if (usedTotalLine) confidence += 0.2;
  if (dateParsed) confidence += 0.1;
  if (gstPrinted) confidence += 0.1;
  if (category !== "office") confidence += 0.05;
  confidence = Math.min(0.75, roundCents(confidence));

  return { merchant, date, total, gst, category, deductible: 100, lineItems, confidence, needsReview: true };
```
  6. Update the `HeuristicReceipt` return type + any caller. In `src/routes/extract.ts` the capped path builds its own object from the heuristic — keep using the heuristic's `category`/`confidence` instead of the hardcoded values (read the capped branch and wire `h.category`/`h.confidence`/`h.needsReview`). The stub path (`stubReceipt`) may keep `confidence: 0.9` (it's a deterministic test stub) but should also use `h.category`.

- [ ] **Step 4: Run — passes:** `npx vitest run test/extractionHeuristic.test.ts test/smart-scan-cap.test.ts test/extract-route.test.ts` → PASS. Then full `npm test` → green (fix any snapshot/shape assertions that referenced the old hardcoded `category:"office"`).

- [ ] **Step 5: Commit.**
```bash
git add src/lib/extractionHeuristic.ts src/routes/extract.ts test/extractionHeuristic.test.ts
git commit -m "$(cat <<'EOF'
feat(heuristic): server parser — total-line preference, category, graded confidence

Prefer an explicit TOTAL line over CASH/tendered; infer category from the
merchant map; emit graded confidence. Benefits the smart-scan-cap + DeepSeek
-outage fallbacks (which run this server parser).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — Swift `ParsedReceipt` gains category + confidence; un-hardcode the draft init

**Files:**
- Modify: `Snapceipt/Features/Capture/Scanner/HeuristicParser.swift` (the `ParsedReceipt` struct, lines 5–12)
- Modify: `Snapceipt/Features/Capture/ExtractedReceipt.swift` (the `init(parsed:capturedAt:)`, lines 146–160)
- Test: `SnapceiptTests/HeuristicParserTests.swift`

- [ ] **Step 1: Write the failing test.** In `HeuristicParserTests.swift` add (uses the existing `lines(_:)` helper):

```swift
@Test func parsedReceiptCarriesCategoryAndConfidence() {
    let r = HeuristicParser.parse(lines(["WOOLWORTHS METRO", "TOTAL 12.00"]))
    #expect(r.category == .groceries)
    #expect(r.confidence >= 0.3 && r.confidence <= 0.75)
}
```

- [ ] **Step 2: Run — fails** (no `category`/`confidence` on `ParsedReceipt`): build/test fails to compile.
Run: `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/HeuristicParserTests` → FAIL (compile).

- [ ] **Step 3: Implement.** In `HeuristicParser.swift`, extend `ParsedReceipt`:

```swift
struct ParsedReceipt {
    var merchant: String = ""
    var date: Date = .now
    var total: Decimal = 0
    var tax: Decimal?
    var currencyCode: String = "AUD"
    var lineItems: [(name: String, price: Decimal)] = []
    var category: CategoryKey = .office
    var confidence: Double = 0.3
}
```
In `ExtractedReceipt.swift` `init(parsed:capturedAt:)` replace the hardcoded `categoryKey: "office"` and `confidence: 0.4` with `categoryKey: parsed.category.rawValue` and `confidence: parsed.confidence` (keep `deductible: 100`, `needsReview: true`, `extractionStatus: "pending"`).

- [ ] **Step 4: Run — still fails** the assertion (parser doesn't set category yet) but compiles. That's expected; Task 4 sets the values. To keep this task self-contained, also have `parse` set `result.category = .office` and `result.confidence = 0.3` defaults explicitly at the end (so the test compiles + the `confidence` range passes; the `== .groceries` assertion will pass once Task 5 lands). **If you prefer strict red→green per task, move the `parsedReceiptCarriesCategoryAndConfidence` assertion's `== .groceries` check into Task 5 and assert only the confidence range + `.office` default here.** Run the same xcodebuild test → PASS for the range/default.

- [ ] **Step 5: Commit.**
```bash
git add Snapceipt/Features/Capture/Scanner/HeuristicParser.swift Snapceipt/Features/Capture/ExtractedReceipt.swift SnapceiptTests/HeuristicParserTests.swift
git commit -m "$(cat <<'EOF'
refactor(heuristic): ParsedReceipt carries category + confidence (un-hardcode draft)

Offline draft init no longer hardcodes office/0.4 — it reads the parser's
category + graded confidence (set in the following tasks).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — Swift Tier 1: date-skip in amounts, word-boundary GST, total algorithm

**Files:**
- Modify: `Snapceipt/Features/Capture/Scanner/HeuristicParser.swift`
- Test: `SnapceiptTests/HeuristicParserTests.swift`

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func dotSeparatedDateNotPickedAsTotal() {
    let r = HeuristicParser.parse(lines(["Acme Pty Ltd", "28.05.2026", "TOTAL 9.00"]))
    #expect(r.total == Decimal(string: "9.00"))
}
@Test func taxiLineIsNotReadAsGst() {
    let r = HeuristicParser.parse(lines(["City Cabs", "Taxi fare 25.00", "TOTAL 25.00"]))
    // No printed GST line -> GST inferred as total/11, NOT 25.00 from "Taxi".
    #expect(r.tax == Decimal(string: "2.27"))
}
@Test func cashTenderedDoesNotBeatTotal() {
    let r = HeuristicParser.parse(lines(["Shop", "Item 4.50", "TOTAL 4.50", "CASH 50.00", "CHANGE 45.50"]))
    #expect(r.total == Decimal(string: "4.50"))
}
```

- [ ] **Step 2: Run — fails:** `xcodebuild test ... -only-testing:SnapceiptTests/HeuristicParserTests` → FAIL (current code: "tax" substring matches "Taxi" → tax 25.00; CASH 50.00 wins largest; dot-date may inject 28.05).

- [ ] **Step 3: Implement.** In `HeuristicParser.swift`:
  1. Add a date-line detector reused everywhere amounts are scanned:
```swift
private static let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
private static func isDateLine(_ s: String) -> Bool {
    guard let d = dateDetector else { return false }
    let r = NSRange(s.startIndex..., in: s)
    return d.firstMatch(in: s, range: r)?.date != nil
}
```
  2. **Total** — replace the existing total block with the unified algorithm:
```swift
let nonDate = texts.filter { !isDateLine($0) }
func maxAmount(_ ls: [String]) -> Decimal? { ls.flatMap(amounts).max() }
let totalLines = nonDate.filter { let l = $0.lowercased(); return l.contains("total") && !l.contains("subtotal") && !l.contains("sub total") }
let tenderRe = #"(?i)\b(total|subtotal|gst|tax|vat|change|cash|eftpos|balance|amount due|tendered|rounding)\b"#
let usedTotalLine: Bool
if let t = maxAmount(totalLines) {
    result.total = t; usedTotalLine = true
} else {
    let nonTender = nonDate.filter { $0.range(of: tenderRe, options: .regularExpression) == nil }
    result.total = maxAmount(nonTender) ?? 0; usedTotalLine = false
}
```
  3. **GST** — change the keyword test from substring `contains` to word-boundary regex so "Taxi"/"Private" don't match:
```swift
let gstRe = #"(?i)\b(gst|tax|vat)\b"#
let gstPrinted: Bool
if let taxLine = texts.first(where: { $0.range(of: gstRe, options: .regularExpression) != nil }),
   let taxVal = amounts(in: taxLine).max() {
    result.tax = taxVal; gstPrinted = true
} else if result.total > 0 {
    result.tax = roundedGST(result.total); gstPrinted = false
} else { gstPrinted = false }
```
  4. Stash `usedTotalLine`/`gstPrinted`/whether a date was found for the confidence step in Task 6 (use local vars carried to the end of `parse`).

- [ ] **Step 4: Run — passes:** the three new tests + all existing `HeuristicParserTests` pass. `xcodebuild test ... -only-testing:SnapceiptTests/HeuristicParserTests` → TEST SUCCEEDED.

- [ ] **Step 5: Commit.**
```bash
git add Snapceipt/Features/Capture/Scanner/HeuristicParser.swift SnapceiptTests/HeuristicParserTests.swift
git commit -m "$(cat <<'EOF'
fix(heuristic): swift parser — skip dates, word-boundary GST, total-line preference

Dot-separated dates no longer become the total; "Taxi"/"Private" no longer
match the GST keyword (word boundaries); an explicit TOTAL line beats a larger
CASH/tendered amount. Parity with the server parser.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5 — Swift Tier 2: line items, category inference, merchant stop-list

**Files:**
- Create: `Snapceipt/Model/ReceiptCategoryHeuristic.swift` (the Swift twin of `receiptCategory.ts`, same keywords)
- Modify: `Snapceipt/Features/Capture/Scanner/HeuristicParser.swift`
- Test: `SnapceiptTests/HeuristicParserTests.swift`, `SnapceiptTests/ReceiptCategoryHeuristicTests.swift` (new)

- [ ] **Step 1: Write failing tests.** New `ReceiptCategoryHeuristicTests.swift`:
```swift
import Testing
@testable import Snapceipt

@Suite struct ReceiptCategoryHeuristicTests {
    @Test func mapsKnownMerchants() {
        #expect(ReceiptCategoryHeuristic.infer(merchant: "WOOLWORTHS 123", lineTexts: []) == .groceries)
        #expect(ReceiptCategoryHeuristic.infer(merchant: "Shell Express", lineTexts: []) == .fuel)
        #expect(ReceiptCategoryHeuristic.infer(merchant: "Bunnings", lineTexts: []) == .home)
        #expect(ReceiptCategoryHeuristic.infer(merchant: "Zzz Pty Ltd", lineTexts: []) == .office)
    }
}
```
And in `HeuristicParserTests.swift`:
```swift
@Test func extractsLineItemsAndCategory() {
    let r = HeuristicParser.parse(lines(["The Coffee Club", "Flat White 4.50", "Muffin 5.50", "TOTAL 10.00"]))
    #expect(r.category == .meals)
    #expect(r.lineItems.count == 2)
    #expect(r.lineItems.first?.name == "Flat White")
    #expect(r.lineItems.first?.price == Decimal(string: "4.50"))
}
@Test func merchantSkipsHeaderNoise() {
    let r = HeuristicParser.parse(lines(["TAX INVOICE", "Bob's Hardware", "TOTAL 5.00"]))
    #expect(r.merchant == "Bob's Hardware")
}
```

- [ ] **Step 2: Run — fails** (no `ReceiptCategoryHeuristic`; lineItems empty; merchant = "TAX INVOICE"). `xcodebuild test ...` → FAIL.

- [ ] **Step 3: Implement.**
  1. New `Snapceipt/Model/ReceiptCategoryHeuristic.swift` — same keyword table as `receiptCategory.ts`, returning `CategoryKey`:
```swift
import Foundation

/// Keyword -> CategoryKey map shared (by value) with src/lib/receiptCategory.ts.
/// Kept in sync via the golden corpus in HeuristicParserTests / extractionHeuristic.test.ts.
enum ReceiptCategoryHeuristic {
    private static let table: [(CategoryKey, [String])] = [
        (.groceries, ["woolworths","coles","aldi","iga","foodland","costco","supabarn"]),
        (.fuel, ["shell","bp","caltex","ampol","mobil","7-eleven","united petroleum"]),
        (.meals, ["cafe","coffee","restaurant","bakery","pizza","mcdonald","kfc","subway","nando","grill","kitchen","eatery","uber eats","doordash","menulog"]),
        (.travel, ["uber","didi","ola","taxi","qantas","jetstar","virgin australia","rex","hotel","motel","airbnb","booking.com","flight","parking","toll","linkt"]),
        (.software, ["apple.com/bill","google","microsoft","adobe","github","aws","amazon web","openai","anthropic","figma","notion","slack","zoom","atlassian","xero","canva"]),
        (.health, ["pharmacy","chemist","priceline","dental","medical","clinic","physio","optical","terry white"]),
        (.home, ["bunnings","ikea","harvey norman","jb hi-fi","the good guys","kmart","target","spotlight","mitre 10"]),
        (.office, ["officeworks","staples","australia post","auspost"]),
    ]
    static func infer(merchant: String, lineTexts: [String]) -> CategoryKey {
        let hay = ([merchant] + lineTexts).joined(separator: " \n ").lowercased()
        for (cat, kws) in table where kws.contains(where: { hay.contains($0) }) { return cat }
        return .office
    }
}
```
  2. In `HeuristicParser.parse`: merchant picker skips a header stop-list and date/amount-only lines:
```swift
let headerStop = ["tax invoice","invoice","receipt","customer copy","merchant copy","eftpos","duplicate"]
result.merchant = texts.first(where: { line in
    let l = line.lowercased()
    let letters = line.filter { $0.isLetter }.count
    return letters >= 3 && !l.contains("www") && !line.contains("@")
        && !isDateLine(line) && !headerStop.contains(where: { l.contains($0) })
}) ?? texts.first ?? ""
```
  3. Populate `result.lineItems` (mirror the TS line-item rule): letter-rich, non-tender lines that carry a cents-bearing amount; strip the trailing price token from the name:
```swift
let priceTokenRe = #"(?:\$\s*)?\d{1,3}(?:[ ,]\d{3})*[.,]\d{2}\s*$"#
for line in texts {
    if line == result.merchant { continue }
    if line.range(of: tenderRe, options: .regularExpression) != nil { continue }
    let letters = line.filter { $0.isLetter }.count
    guard letters >= 2, let price = amounts(in: line).last else { continue }
    let name = line.replacingOccurrences(of: priceTokenRe, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    if name.isEmpty { continue }
    result.lineItems.append((name: name, price: price))
}
```
  4. Set `result.category = ReceiptCategoryHeuristic.infer(merchant: result.merchant, lineTexts: texts)`.

- [ ] **Step 4: Run — passes:** new + existing `HeuristicParserTests` and `ReceiptCategoryHeuristicTests`. `xcodebuild test ...` → TEST SUCCEEDED.

- [ ] **Step 5: Commit.**
```bash
git add Snapceipt/Model/ReceiptCategoryHeuristic.swift Snapceipt/Features/Capture/Scanner/HeuristicParser.swift SnapceiptTests/HeuristicParserTests.swift SnapceiptTests/ReceiptCategoryHeuristicTests.swift
git commit -m "$(cat <<'EOF'
feat(heuristic): swift parser — line items, category map, merchant stop-list

Offline scans now keep line items, get a real category guess (AU merchant map
mirroring receiptCategory.ts), and skip "TAX INVOICE"-style header noise.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — Swift Tier 3 #7: graded confidence

**Files:**
- Modify: `Snapceipt/Features/Capture/Scanner/HeuristicParser.swift`
- Test: `SnapceiptTests/HeuristicParserTests.swift`

- [ ] **Step 1: Write the failing test.**
```swift
@Test func confidenceRisesWithSignals() {
    let weak = HeuristicParser.parse(lines(["Zzz Pty Ltd", "9.00"]))            // no total line, no date, unknown merchant
    let strong = HeuristicParser.parse(lines(["WOOLWORTHS", "TOTAL 11.00", "GST 1.00", "15/06/2026"]))
    #expect(weak.confidence <= 0.4)
    #expect(strong.confidence >= 0.6)
    #expect(strong.confidence <= 0.75)
}
```

- [ ] **Step 2: Run — fails** (confidence is the fixed default). `xcodebuild test ...` → FAIL.

- [ ] **Step 3: Implement.** At the end of `parse`, compute confidence from the signals captured in Tasks 4–5 (`usedTotalLine`, `gstPrinted`, whether the date detector found a date, whether category != .office):
```swift
var confidence = 0.3
if usedTotalLine { confidence += 0.2 }
if dateFound { confidence += 0.1 }          // set true where NSDataDetector matched a date in `joined`
if gstPrinted { confidence += 0.1 }
if result.category != .office { confidence += 0.05 }
result.confidence = min(0.75, confidence)
```
(Make `dateFound` a local set in the existing date block; carry `usedTotalLine`/`gstPrinted` from Task 4.)

- [ ] **Step 4: Run — passes.** `xcodebuild test ... -only-testing:SnapceiptTests/HeuristicParserTests` → TEST SUCCEEDED.

- [ ] **Step 5: Commit.**
```bash
git add Snapceipt/Features/Capture/Scanner/HeuristicParser.swift SnapceiptTests/HeuristicParserTests.swift
git commit -m "$(cat <<'EOF'
feat(heuristic): swift parser — graded confidence (0.30–0.75) from found signals

Confidence reflects whether a total line, date, printed GST, and known merchant
were found, instead of a flat 0.4. needsReview stays true.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7 — Swift Tier 3 #8: plumb OCR geometry to the offline parser

**Files:**
- Modify: `Snapceipt/Features/Capture/CaptureViewModel.swift` (`onScanned`, the offline catch block, add a stored `recognizedLines`)
- Modify: `Snapceipt/Features/Capture/Views/CaptureFlow.swift` (lines 19–25 — pass lines, not just text)
- Modify: `Snapceipt/Features/Capture/Scanner/HeuristicParser.swift` (use geometry when boxes are non-zero)
- Test: `SnapceiptTests/HeuristicParserTests.swift`, `SnapceiptTests/CaptureViewModelTests.swift`

**Vision geometry note:** `boundingBox` is normalized [0,1] with **origin bottom-left**, so the *top* of the receipt is the line with the largest `boundingBox.maxY`; bigger font ≈ larger `boundingBox.height`.

- [ ] **Step 1: Write the failing test (geometry-aware merchant + total tiebreak).** Add a geometry helper to `HeuristicParserTests.swift` and a test:
```swift
private func line(_ t: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> RecognizedLine {
    RecognizedLine(text: t, confidence: 0.9, boundingBox: CGRect(x: x, y: y, width: w, height: h))
}
@Test func geometryPicksTopLineAsMerchantAndBigFontTotal() {
    // y is bottom-left origin: 0.92 is near the top; the 44.00 has a taller box (bigger font).
    let ls = [
        line("WOOLWORTHS METRO", x: 0.1, y: 0.92, w: 0.6, h: 0.03),
        line("Milk 2.00",        x: 0.1, y: 0.60, w: 0.5, h: 0.02),
        line("44.00",            x: 0.7, y: 0.30, w: 0.2, h: 0.05),
    ]
    let r = HeuristicParser.parse(ls)
    #expect(r.merchant == "WOOLWORTHS METRO")
    #expect(r.total == Decimal(string: "44.00"))
}
```

- [ ] **Step 2: Run — fails** (parse ignores geometry; merchant picks first letter-rich text which here is also top, but the total `44.00` has no "total" line and would be the largest anyway — adjust the fixture so geometry is decisive: add a distractor `"99.00"` with a tiny box to prove the big-font 44.00 wins). Update the test fixture to include `line("99.00", x: 0.7, y: 0.10, w: 0.2, h: 0.015)` and expect `44.00`. Run `xcodebuild test ...` → FAIL.

- [ ] **Step 3: Implement.** In `HeuristicParser.parse`, detect whether geometry is present (`lines.contains { $0.boundingBox != .zero }`). When present:
  - Merchant: among letter-rich, non-stop, non-date lines, pick the one with the greatest `boundingBox.maxY` (topmost).
  - Total tiebreak: when there is no explicit "total" line, among amount-bearing non-tender lines prefer the amount on the line with the greatest `boundingBox.height` (largest font); fall back to max value on ties.
  When geometry is absent (`.zero`), keep the text-only logic from Tasks 4–5 unchanged (this preserves all existing `.zero`-box tests).

- [ ] **Step 4: Plumb the real lines through the flow.**
  1. `CaptureViewModel`: add `private(set) var recognizedLines: [RecognizedLine] = []`. Change `onScanned` to `func onScanned(image: UIImage, lines: [RecognizedLine]) async` — set `self.recognizedLines = lines`, `self.rawText = lines.map(\.text).joined(separator: "\n")`, then the rest unchanged. In the offline `catch`, call `HeuristicParser.parse(recognizedLines)` (real boxes) instead of rebuilding from `rawText.split`.
  2. `CaptureFlow.swift` (lines 19–25): change the closure to pass the lines:
```swift
onScanned: { image in
    Task {
        let lines = (try? await OCR.recognize(in: image)) ?? []
        await vm.onScanned(image: image, lines: lines)
    }
},
```
  3. Update any other `onScanned(image:rawText:)` caller (grep `onScanned(image`) — e.g. tests/`PendingExtractionReconciler` use `/extract` with `ocrText`, not this VM method; the VM method's only production caller is `CaptureFlow`. Update `CaptureViewModelTests` that call `onScanned` to pass `lines:` (wrap their rawText in `[RecognizedLine(text:confidence:boundingBox:.zero)]` so behavior is unchanged).

- [ ] **Step 5: Run — passes.** `xcodebuild test -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SnapceiptTests/HeuristicParserTests -only-testing:SnapceiptTests/CaptureViewModelTests` → TEST SUCCEEDED. Then a full `xcodebuild build` (the signature change touches CaptureFlow).

- [ ] **Step 6: Commit.**
```bash
git add Snapceipt/Features/Capture/CaptureViewModel.swift Snapceipt/Features/Capture/Views/CaptureFlow.swift Snapceipt/Features/Capture/Scanner/HeuristicParser.swift SnapceiptTests/HeuristicParserTests.swift SnapceiptTests/CaptureViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(heuristic): use OCR geometry offline (topmost=merchant, big-font=total)

Plumb the real [RecognizedLine] (with bounding boxes) from CaptureFlow through
onScanned to the offline parser; use position/font-size when present, with a
.zero-box text-only fallback so existing callers/tests are unaffected.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8 — Tier 4: shared golden-file corpus (Swift + TS read the same fixtures)

**Files:**
- Create: `test/fixtures/heuristic-receipts.json`
- Modify: `test/extractionHeuristic.test.ts` (read + assert the corpus)
- Modify: `SnapceiptTests/HeuristicParserTests.swift` (read the corpus via `#filePath`-relative path + assert)

The corpus asserts only the fields **both** parsers produce from plain text: `merchant`, `date`, `total`, `gst`, `category`. (Geometry is iOS-only and not represented here.)

- [ ] **Step 1: Create the corpus.** `test/fixtures/heuristic-receipts.json`:
```json
[
  { "name": "woolworths groceries", "ocrText": "WOOLWORTHS METRO\n15/06/2026\nMilk 2.00\nBread 3.50\nTOTAL 5.50\nGST 0.50",
    "expect": { "merchant": "WOOLWORTHS METRO", "date": "2026-06-15", "total": 5.50, "gst": 0.50, "category": "groceries" } },
  { "name": "fuel no printed gst", "ocrText": "Shell Coles Express\n01/06/2026\nUnleaded 80.00\nTOTAL 80.00",
    "expect": { "merchant": "Shell Coles Express", "date": "2026-06-01", "total": 80.00, "gst": 7.27, "category": "fuel" } },
  { "name": "cafe meals with cash tendered", "ocrText": "The Coffee Club\nFlat White 4.50\nTOTAL 4.50\nCASH 50.00\nCHANGE 45.50",
    "expect": { "merchant": "The Coffee Club", "date": null, "total": 4.50, "gst": 0.41, "category": "meals" } },
  { "name": "taxi not gst", "ocrText": "City Cabs\nTaxi fare 25.00\nTOTAL 25.00",
    "expect": { "merchant": "City Cabs", "date": null, "total": 25.00, "gst": 2.27, "category": "travel" } }
]
```
(`date: null` means "no date in text → caller default", which the tests pass per-parser.)

- [ ] **Step 2: TS test reads the corpus.** In `test/extractionHeuristic.test.ts`:
```ts
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const corpus = JSON.parse(readFileSync(fileURLToPath(new URL("./fixtures/heuristic-receipts.json", import.meta.url)), "utf8"));
describe("shared heuristic corpus", () => {
  for (const c of corpus) it(c.name, () => {
    const r = heuristicExtract(c.ocrText, "2026-01-01");
    expect(r.merchant).toBe(c.expect.merchant);
    if (c.expect.date) expect(r.date).toBe(c.expect.date);
    expect(r.total).toBe(c.expect.total);
    expect(r.gst).toBe(c.expect.gst);
    expect(r.category).toBe(c.expect.category);
  });
});
```
Run `npx vitest run test/extractionHeuristic.test.ts` → adjust the server parser if any corpus case fails (the corpus is the contract).

- [ ] **Step 3: Swift test reads the SAME corpus.** In `HeuristicParserTests.swift`, locate the repo file from the test source path and assert (Swift Testing exposes the source location; derive the repo root from `#filePath`):
```swift
import Foundation
@Test func sharedCorpusMatches() throws {
    // SnapceiptTests/HeuristicParserTests.swift -> repo root is two levels up.
    let here = URL(fileURLToPath: #filePath)
    let root = here.deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("test/fixtures/heuristic-receipts.json"))
    struct Case: Decodable { let name: String; let ocrText: String; let expect: Expect
        struct Expect: Decodable { let merchant: String; let date: String?; let total: Double; let gst: Double; let category: String } }
    let cases = try JSONDecoder().decode([Case].self, from: data)
    for c in cases {
        let r = HeuristicParser.parse(lines(c.ocrText.split(separator: "\n").map(String.init)))
        #expect(r.merchant == c.expect.merchant, "\(c.name): merchant")
        #expect(NSDecimalNumber(decimal: r.total).doubleValue == c.expect.total, "\(c.name): total")
        if let tax = r.tax { #expect(NSDecimalNumber(decimal: tax).doubleValue == c.expect.gst, "\(c.name): gst") }
        #expect(r.category.rawValue == c.expect.category, "\(c.name): category")
    }
}
```
(If reading the repo path from the test sandbox proves unavailable on the CI simulator, fall back to embedding the corpus as a Swift resource in the test target via `project.yml` and load it with `Bundle.module`/the test bundle — note which you used.)

- [ ] **Step 4: Run both.** `npx vitest run test/extractionHeuristic.test.ts` and `xcodebuild test ... -only-testing:SnapceiptTests/HeuristicParserTests` → both green. Any divergence between the parsers shows up here; fix the lagging parser, not the corpus.

- [ ] **Step 5: Commit.**
```bash
git add test/fixtures/heuristic-receipts.json test/extractionHeuristic.test.ts SnapceiptTests/HeuristicParserTests.swift
git commit -m "$(cat <<'EOF'
test(heuristic): shared golden corpus asserted by BOTH swift + ts parsers

A single fixtures file both parsers must satisfy (merchant/date/total/gst/
category) so the Swift and TypeScript heuristics can't silently drift again.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9 — Full regression sweep

- [ ] **Step 1: Backend** — `npm test` → all green (includes the new receiptCategory, extractionHeuristic corpus, smart-scan-cap, extract-route). `npm run typecheck` → no new errors (the 2 pre-existing `vitest.config.ts` errors are expected).
- [ ] **Step 2: iOS** — `xcodegen generate` then `xcodebuild -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 16' build` → BUILD SUCCEEDED, and `xcodebuild test ... -only-testing:SnapceiptTests/HeuristicParserTests -only-testing:SnapceiptTests/ReceiptCategoryHeuristicTests -only-testing:SnapceiptTests/CaptureViewModelTests -only-testing:SnapceiptTests/ExtractionResponseTests` → TEST SUCCEEDED.
- [ ] **Step 3: Confirm no behaviour regressions** on the LLM path: `/extract` under-cap still returns the DeepSeek result unchanged; only the heuristic fallbacks (offline + capped + outage) gain category/confidence. (Read `src/routes/extract.ts` to confirm the LLM branch is untouched.)

---

## Open questions (human input)

- **Deductible per category:** the heuristic keeps `deductible: 100` for every category (matches today). If you want meals at 50% etc., that's a tax rule to add to the category map later — left out of scope here.
- **Category breadth:** the keyword lists are a starter set of common AU merchants; extend as real misses show up. Keeping the Swift + TS lists identical is enforced by the Task 8 corpus only for the cases it contains — add a corpus row when you add a merchant you care about.
