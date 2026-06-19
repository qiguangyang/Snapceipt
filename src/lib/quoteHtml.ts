/**
 * Pure server-rendered HTML quote page (spec §4). Self-contained: inline CSS,
 * mobile-responsive + print-friendly, no external assets (the logo is inlined as a
 * data-URI by the caller). Rendered on the fly by GET /q/:token so it always reflects
 * the live quote. Totals are recomputed by the route and passed in. iOS loads the same
 * URL in a hidden WKWebView and renders it to PDF on demand.
 */

export interface QuoteHtmlBusiness {
  name: string;
  abn: string | null;
  businessEmail: string | null;
  phone: string | null;
  website: string | null;
  address: string | null;
  bankDetails: string | null;
}

export interface QuoteHtmlLineItem {
  description: string;
  quantity: number;
  unitPriceCents: number;
}

export interface QuoteHtmlData {
  number: string | null;
  /** YYYY-MM-DD issued date. */
  issuedDate: string;
  validUntil: string | null;
  clientName: string | null;
  clientEmail: string | null;
  gstEnabled: boolean;
  gstInclusive: boolean;
  /** Basis points; null ⇒ label "GST (10%)". */
  gstRateBp: number | null;
  subtotalCents: number;
  gstCents: number;
  totalCents: number;
  business: QuoteHtmlBusiness;
  lineItems: QuoteHtmlLineItem[];
  /** data:image/...;base64,... or null when no logo. */
  logoDataUri: string | null;
  /** App link for the footer badge. */
  appUrl: string;
}

const DEFAULT_GST_RATE_BP = 1000;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

/** Format a basis-point rate as a percent string ("15", "12.5", "10"). */
function ratePct(bp: number | null): string {
  const v = (bp ?? DEFAULT_GST_RATE_BP) / 100;
  return Number.isInteger(v) ? String(v) : String(v);
}

/** HTML-escape a string (text + attribute safe). null/undefined ⇒ "". */
function esc(s: string | null | undefined): string {
  if (s == null) return "";
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** Escape then turn newlines into <br> for multiline fields (address, bank details). */
function escMultiline(s: string | null | undefined): string {
  return esc(s).replace(/\n/g, "<br>");
}

export function renderQuoteHtml(data: QuoteHtmlData): string {
  const b = data.business;
  const inclusive = data.gstEnabled && data.gstInclusive;

  const logo = data.logoDataUri
    ? `<img class="logo" src="${esc(data.logoDataUri)}" alt="${esc(b.name)} logo">`
    : "";

  const contactLines: string[] = [];
  if (b.abn) contactLines.push(`ABN ${esc(b.abn)}`);
  if (b.businessEmail) contactLines.push(esc(b.businessEmail));
  if (b.phone) contactLines.push(esc(b.phone));
  if (b.website) contactLines.push(esc(b.website));
  const contactHtml = contactLines.length ? `<div class="muted">${contactLines.join(" &middot; ")}</div>` : "";
  const addressHtml = b.address ? `<div class="muted">${escMultiline(b.address)}</div>` : "";

  const rows = data.lineItems
    .map((li) => {
      const amount = li.quantity * li.unitPriceCents;
      return `<tr>
        <td>${esc(li.description)}</td>
        <td class="num">${li.quantity}</td>
        <td class="num">${dollars(li.unitPriceCents)}</td>
        <td class="num">${dollars(amount)}</td>
      </tr>`;
    })
    .join("");

  const gstLine = data.gstEnabled
    ? `<tr><td>GST (${esc(ratePct(data.gstRateBp))}%)${inclusive ? " incl." : ""}</td><td class="num">${dollars(data.gstCents)}</td></tr>`
    : "";

  const validNote = data.validUntil
    ? `<p class="muted small">Valid until ${esc(data.validUntil)}. Accepted quotes convert to a tax invoice.</p>`
    : `<p class="muted small">Accepted quotes convert to a tax invoice.</p>`;

  const paymentBlock = b.bankDetails
    ? `<section class="card">
        <h2>Payment details</h2>
        <div class="muted">${escMultiline(b.bankDetails)}</div>
      </section>`
    : "";

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Quote ${esc(data.number ?? "")} — ${esc(b.name)}</title>
<style>
  :root { --ink:#111827; --muted:#6b7280; --line:#e5e7eb; --brand:#0E7C72; }
  * { box-sizing: border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
         color:var(--ink); background:#f3f4f6; line-height:1.5; }
  .page { max-width:760px; margin:24px auto; background:#fff; padding:40px;
          border-radius:12px; box-shadow:0 1px 4px rgba(0,0,0,.06); }
  .head { display:flex; justify-content:space-between; align-items:flex-start; gap:24px; flex-wrap:wrap; }
  .logo { max-height:64px; max-width:200px; object-fit:contain; }
  h1 { font-size:22px; margin:0 0 2px; }
  h2 { font-size:14px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); margin:0 0 8px; }
  .muted { color:var(--muted); font-size:14px; }
  .small { font-size:12px; }
  .meta { text-align:right; }
  .meta .big { font-size:20px; font-weight:600; }
  .card { margin-top:28px; padding-top:20px; border-top:1px solid var(--line); }
  table { width:100%; border-collapse:collapse; margin-top:8px; font-size:14px; }
  th, td { padding:8px 6px; text-align:left; border-bottom:1px solid var(--line); }
  th { color:var(--muted); font-weight:600; font-size:12px; text-transform:uppercase; letter-spacing:.03em; }
  .num { text-align:right; white-space:nowrap; }
  .totals { width:100%; max-width:280px; margin-left:auto; margin-top:12px; font-size:14px; }
  .totals td { border:none; padding:4px 6px; }
  .totals tr.total td { border-top:2px solid var(--ink); font-weight:700; font-size:16px; padding-top:8px; }
  .badge { margin-top:32px; text-align:center; }
  .badge a { color:var(--brand); text-decoration:none; font-size:12px; }
  @media print { body { background:#fff; } .page { box-shadow:none; margin:0; max-width:none; border-radius:0; } }
</style>
</head>
<body>
  <div class="page">
    <header class="head">
      <div>
        ${logo}
        <h1>${esc(b.name)}</h1>
        ${contactHtml}
        ${addressHtml}
      </div>
      <div class="meta">
        <div class="big">Quote ${esc(data.number ?? "")}</div>
        <div class="muted">Issued ${esc(data.issuedDate)}</div>
      </div>
    </header>

    <section class="card">
      <h2>Bill to</h2>
      <div>${esc(data.clientName ?? "")}</div>
      ${data.clientEmail ? `<div class="muted">${esc(data.clientEmail)}</div>` : ""}
    </section>

    <section class="card">
      <h2>Items</h2>
      <table>
        <thead><tr><th>Description</th><th class="num">Qty</th><th class="num">Unit</th><th class="num">Amount</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
      <table class="totals">
        <tr><td>${inclusive ? "Subtotal (ex GST)" : "Subtotal"}</td><td class="num">${dollars(data.subtotalCents)}</td></tr>
        ${gstLine}
        <tr class="total"><td>Total</td><td class="num">${dollars(data.totalCents)}</td></tr>
      </table>
      ${inclusive ? `<p class="muted small">Prices include GST.</p>` : ""}
      ${validNote}
    </section>

    ${paymentBlock}

    <div class="badge"><a href="${esc(data.appUrl)}">Made with Snapceipt</a></div>
  </div>
</body>
</html>`;
}
