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
  /** Freeform multiline client address; rendered in the To block only when non-empty. */
  clientAddress: string | null;
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

/** Dollars with a leading sign, e.g. "$40.00". */
function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

/** Bare 2-dp amount (no sign), e.g. "40.00" — used for the Unit Price column. */
function amount(cents: number): string {
  return (cents / 100).toFixed(2);
}

/** Format a basis-point rate as a percent string ("15", "12.5", "10"). */
function ratePct(bp: number | null): string {
  return String((bp ?? DEFAULT_GST_RATE_BP) / 100);
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

function metaRow(k: string, v: string): string {
  return `<tr><td class="k">${k}</td><td class="v">${v}</td></tr>`;
}

export function renderQuoteHtml(data: QuoteHtmlData): string {
  const b = data.business;
  const inclusive = data.gstEnabled && data.gstInclusive;

  const logo = data.logoDataUri
    ? `<img class="logo" src="${esc(data.logoDataUri)}" alt="${esc(b.name)} logo">`
    : "";

  // Company contact lines under the name (each only when set).
  const companyLines: string[] = [];
  if (b.address) companyLines.push(escMultiline(b.address));
  const contactBits: string[] = [];
  if (b.businessEmail) contactBits.push(esc(b.businessEmail));
  if (b.phone) contactBits.push(esc(b.phone));
  if (b.website) contactBits.push(esc(b.website));
  if (contactBits.length) companyLines.push(contactBits.join(" &middot; "));
  if (b.abn) companyLines.push(`ABN ${esc(b.abn)}`);
  const companyMeta = companyLines.map((l) => `<div class="muted">${l}</div>`).join("");

  // Bill-to lines under the client name: optional multiline address, then email.
  const toLines: string[] = [];
  if (data.clientAddress) toLines.push(`<div class="muted">${escMultiline(data.clientAddress)}</div>`);
  if (data.clientEmail) toLines.push(`<div class="muted">${esc(data.clientEmail)}</div>`);

  // Right-hand meta rows.
  const metaRows: string[] = [];
  if (data.number) metaRows.push(metaRow("Quote #", esc(data.number)));
  metaRows.push(metaRow("Quote date", esc(data.issuedDate)));
  if (data.validUntil) metaRows.push(metaRow("Due date", esc(data.validUntil)));

  const rows = data.lineItems
    .map((li) => {
      const lineAmount = li.quantity * li.unitPriceCents;
      return `<tr>
        <td class="qty">${li.quantity}</td>
        <td>${esc(li.description)}</td>
        <td class="num">${amount(li.unitPriceCents)}</td>
        <td class="num">${dollars(lineAmount)}</td>
      </tr>`;
    })
    .join("");

  const gstLine = data.gstEnabled
    ? `<tr><td>GST (${esc(ratePct(data.gstRateBp))}%)${inclusive ? " incl." : ""}</td><td class="num">${dollars(data.gstCents)}</td></tr>`
    : "";

  // Terms & conditions: validity note + payment/bank details.
  const termsLines: string[] = [];
  termsLines.push(
    data.validUntil
      ? `Valid until ${esc(data.validUntil)}. Accepted quotes convert to a tax invoice.`
      : `Accepted quotes convert to a tax invoice.`
  );
  if (b.bankDetails) termsLines.push(`Payment details: ${escMultiline(b.bankDetails)}`);
  const termsHtml = termsLines.map((l) => `<p class="terms-line">${l}</p>`).join("");

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Quote ${esc(data.number ?? "")} — ${esc(b.name)}</title>
<style>
  :root { --ink:#1f2937; --muted:#6b7280; --line:#dfe3e0; --brand:#4f7a63; --brand-soft:#eaf1ec; }
  * { box-sizing:border-box; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
         color:var(--ink); background:#eceeec; line-height:1.5; -webkit-font-smoothing:antialiased; }
  .page { max-width:820px; margin:24px auto; background:#fff; padding:56px 56px 40px;
          border-radius:8px; box-shadow:0 1px 6px rgba(0,0,0,.07); }

  .head { display:flex; justify-content:space-between; align-items:flex-start; gap:24px; }
  .company h1 { font-size:26px; font-weight:600; margin:0 0 6px; }
  .muted { color:var(--muted); font-size:14px; }
  .logo { max-height:96px; max-width:240px; object-fit:contain; }

  .title { text-align:right; font-size:48px; font-weight:800; letter-spacing:.14em;
           color:var(--brand); margin:24px 0 36px; }

  .parties { display:flex; justify-content:space-between; align-items:flex-start; gap:24px; }
  .label { color:var(--brand); font-weight:700; font-size:13px; }
  .to .name { font-size:22px; font-weight:500; margin:2px 0 6px; }
  .meta { border-collapse:collapse; }
  .meta td { padding:3px 0; font-size:14px; }
  .meta .k { color:var(--brand); font-weight:700; text-align:right; padding-right:22px; white-space:nowrap; }
  .meta .v { text-align:right; white-space:nowrap; }

  table.items { width:100%; border-collapse:collapse; margin-top:40px; font-size:15px; }
  table.items thead th { background:var(--brand); color:#fff; font-weight:700; font-size:13px;
                         padding:11px 14px; text-align:left; }
  table.items thead th.num { text-align:right; }
  table.items tbody td { padding:13px 14px; border:none; }
  .qty { white-space:nowrap; }
  .num { text-align:right; white-space:nowrap; }

  .totals-wrap { display:flex; justify-content:flex-end; margin-top:6px; }
  table.totals { border-collapse:collapse; min-width:320px; }
  table.totals td { padding:9px 14px; font-size:15px; }
  table.totals td.num { text-align:right; }
  table.totals tr.first td { border-top:1px solid var(--brand); }
  table.totals tr.total td { background:var(--brand-soft); color:var(--brand); font-weight:700; }

  .terms { margin-top:40px; }
  .terms h2 { color:var(--brand); font-weight:700; font-size:15px; margin:0 0 10px; }
  .terms-line { margin:0 0 8px; font-size:14px; }

  .sign { margin-top:64px; display:flex; justify-content:flex-end; }
  .sign-box { width:260px; text-align:right; }
  .sign-line { border-top:1px solid var(--brand); margin-bottom:6px; }
  .sign-label { color:var(--brand); font-size:13px; }

  .badge { margin-top:28px; text-align:center; }
  .badge a { color:var(--muted); text-decoration:none; font-size:11px; letter-spacing:.02em; }

  @media print {
    body { background:#fff; }
    .page { box-shadow:none; margin:0; max-width:none; border-radius:0; padding:32px; }
  }
  @media (max-width:600px) {
    .page { padding:28px 22px; }
    .head, .parties { flex-direction:column; }
    .title { font-size:38px; text-align:left; }
    .meta .k, .meta .v { text-align:left; }
  }
</style>
</head>
<body>
  <div class="page">
    <header class="head">
      <div class="company">
        <h1>${esc(b.name)}</h1>
        ${companyMeta}
      </div>
      <div>${logo}</div>
    </header>

    <div class="title">QUOTE</div>

    <section class="parties">
      <div class="to">
        <div class="label">To</div>
        <div class="name">${esc(data.clientName ?? "")}</div>
        ${toLines.join("")}
      </div>
      <table class="meta"><tbody>${metaRows.join("")}</tbody></table>
    </section>

    <table class="items">
      <thead>
        <tr><th class="qty">QTY</th><th>Description</th><th class="num">Unit Price</th><th class="num">Amount</th></tr>
      </thead>
      <tbody>${rows}</tbody>
    </table>

    <div class="totals-wrap">
      <table class="totals"><tbody>
        <tr class="first"><td>${inclusive ? "Subtotal (ex GST)" : "Subtotal"}</td><td class="num">${dollars(data.subtotalCents)}</td></tr>
        ${gstLine}
        <tr class="total"><td>Total (AUD)</td><td class="num">${dollars(data.totalCents)}</td></tr>
      </tbody></table>
    </div>

    <section class="terms">
      <h2>Terms and Conditions</h2>
      ${termsHtml}
    </section>

    <div class="sign">
      <div class="sign-box">
        <div class="sign-line"></div>
        <div class="sign-label">customer signature</div>
      </div>
    </div>

    <div class="badge"><a href="${esc(data.appUrl)}">Made with Snapceipt</a></div>
  </div>
</body>
</html>`;
}
