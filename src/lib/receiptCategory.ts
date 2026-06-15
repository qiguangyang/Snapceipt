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

/**
 * First category whose keyword appears in the merchant (then any line text); else "office".
 * When the merchant contains keywords from multiple categories, the keyword that appears
 * earliest (lowest character index) in the merchant string wins.
 */
export function inferCategory(merchant: string, lineTexts: string[]): string {
  const merchantLower = merchant.toLowerCase();
  // Find the earliest-occurring keyword match in the merchant name.
  let bestCat: string | null = null;
  let bestIdx = Infinity;
  for (const [cat, kws] of CATEGORY_KEYWORDS) {
    for (const kw of kws) {
      const idx = merchantLower.indexOf(kw);
      if (idx !== -1 && idx < bestIdx) {
        bestIdx = idx;
        bestCat = cat;
      }
    }
  }
  if (bestCat !== null) return bestCat;
  // No merchant match — scan line items (table order wins on ties).
  const linesHay = lineTexts.join(" \n ").toLowerCase();
  for (const [cat, kws] of CATEGORY_KEYWORDS) {
    if (kws.some((kw) => linesHay.includes(kw))) return cat;
  }
  return "office";
}
