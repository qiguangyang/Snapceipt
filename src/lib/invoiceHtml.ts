/**
 * Pure server-rendered HTML tax-invoice page (mirrors quoteHtml.ts). Self-contained: inline
 * CSS, mobile-responsive + print-friendly, no external assets (the logo is inlined as a
 * data-URI by the caller). Rendered on the fly by GET /i/:token so it always reflects the live
 * invoice. Totals are recomputed by the route and passed in. Unlike the quote page there is no
 * Accept action — an invoice is a demand for payment; it shows payment/bank details, the
 * balance due, and a "PAID" banner once payments cover the total.
 */

export interface InvoiceHtmlBusiness {
  name: string;
  abn: string | null;
  businessEmail: string | null;
  phone: string | null;
  website: string | null;
  address: string | null;
  bankDetails: string | null;
}

export interface InvoiceHtmlLineItem {
  description: string;
  unitLabel?: string | null;
  quantity: number;
  unitPriceCents: number;
}

export interface InvoiceHtmlData {
  number: string | null;
  /** YYYY-MM-DD issue date. */
  issueDate: string;
  dueDate: string | null;
  clientName: string | null;
  clientEmail: string | null;
  gstEnabled: boolean;
  gstInclusive: boolean;
  /** Basis points; null ⇒ label "GST (10%)". */
  gstRateBp: number | null;
  subtotalCents: number;
  gstCents: number;
  totalCents: number;
  /** Σ recorded payments; drives the Amount paid / Balance due rows + the PAID banner. */
  amountPaidCents: number;
  business: InvoiceHtmlBusiness;
  lineItems: InvoiceHtmlLineItem[];
  /** data:image/...;base64,... or null when no logo. */
  logoDataUri: string | null;
  /** App link for the footer badge. */
  appUrl: string;
}

const DEFAULT_GST_RATE_BP = 1000;

function dollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}
function amount(cents: number): string {
  return (cents / 100).toFixed(2);
}
function ratePct(bp: number | null): string {
  return String((bp ?? DEFAULT_GST_RATE_BP) / 100);
}
function esc(s: string | null | undefined): string {
  if (s == null) return "";
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
function escMultiline(s: string | null | undefined): string {
  return esc(s).replace(/\n/g, "<br>");
}
function metaRow(k: string, v: string): string {
  return `<tr><td class="k">${k}</td><td class="v">${v}</td></tr>`;
}

export function renderInvoiceHtml(data: InvoiceHtmlData): string {
  const b = data.business;
  const inclusive = data.gstEnabled && data.gstInclusive;
  const balanceCents = data.totalCents - data.amountPaidCents;
  const isPaid = data.amountPaidCents > 0 && balanceCents <= 0;

  const logo = data.logoDataUri
    ? `<img class="logo" src="${esc(data.logoDataUri)}" alt="${esc(b.name)} logo">`
    : "";

  const companyLines: string[] = [];
  if (b.address) companyLines.push(escMultiline(b.address));
  if (b.businessEmail) companyLines.push(esc(b.businessEmail));
  if (b.phone) companyLines.push(esc(b.phone));
  if (b.website) companyLines.push(esc(b.website));
  if (b.abn) companyLines.push(`ABN ${esc(b.abn)}`);
  const companyMeta = companyLines.map((l) => `<div class="muted">${l}</div>`).join("");

  const toLines: string[] = [];
  if (data.clientEmail) toLines.push(`<div class="muted">${esc(data.clientEmail)}</div>`);

  const metaRows: string[] = [];
  if (data.number) metaRows.push(metaRow("Invoice #", esc(data.number)));
  metaRows.push(metaRow("Issue date", esc(data.issueDate)));
  if (data.dueDate) metaRows.push(metaRow("Due date", esc(data.dueDate)));

  const rows = data.lineItems
    .map((li) => {
      const lineAmount = li.quantity * li.unitPriceCents;
      return `<tr>
        <td class="qty">${esc(String(li.quantity))}</td>
        <td>${esc(li.description)}${li.unitLabel ? ` <span class="muted">(${esc(li.unitLabel)})</span>` : ""}</td>
        <td class="num">${amount(li.unitPriceCents)}</td>
        <td class="num">${dollars(lineAmount)}</td>
      </tr>`;
    })
    .join("");

  const gstLine = data.gstEnabled
    ? `<tr><td>GST (${esc(ratePct(data.gstRateBp))}%)${inclusive ? " incl." : ""}</td><td class="num">${dollars(data.gstCents)}</td></tr>`
    : "";

  // Amount paid + Balance due rows appear only once a payment is recorded.
  const paidRows =
    data.amountPaidCents > 0
      ? `<tr><td>Amount paid</td><td class="num">&minus;${dollars(data.amountPaidCents)}</td></tr>
         <tr class="total"><td>Balance due (AUD)</td><td class="num">${dollars(Math.max(0, balanceCents))}</td></tr>`
      : `<tr class="total"><td>Total (AUD)</td><td class="num">${dollars(data.totalCents)}</td></tr>`;

  // Payment terms: due note + bank/payment details (the heart of an invoice).
  const termsLines: string[] = [];
  termsLines.push(
    data.dueDate
      ? `Payment due by ${esc(data.dueDate)}.`
      : `Payment due on receipt.`,
  );
  if (b.bankDetails) termsLines.push(`Payment details:<br>${escMultiline(b.bankDetails)}`);
  const termsHtml = termsLines.map((l) => `<p class="terms-line">${l}</p>`).join("");

  const paidBanner = isPaid
    ? `<div class="paid-banner">Paid &#10003;</div>`
    : "";

  const actionsHtml = `<div class="actions" id="actions">
      <button type="button" class="btn btn-secondary" onclick="window.print()">Save as PDF</button>
    </div>`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Tax invoice ${esc(data.number ?? "")} — ${esc(b.name)}</title>
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

  .title { text-align:right; font-size:44px; font-weight:800; letter-spacing:.12em;
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

  .actions { margin-top:36px; display:flex; gap:12px; flex-wrap:wrap; }
  .btn { appearance:none; border:none; cursor:pointer; font:inherit; font-weight:700; font-size:15px;
         padding:13px 26px; border-radius:8px; }
  .btn-secondary { background:var(--brand-soft); color:var(--brand); }
  .paid-banner { margin-top:36px; padding:16px 20px; border-radius:8px; background:var(--brand-soft);
                 color:var(--brand); font-weight:700; font-size:16px; text-align:center; }

  .footer { margin-top:36px; text-align:center; }
  .footer a { color:var(--muted); text-decoration:none; font-size:12px; }

  .badge { margin-top:28px; text-align:center; }
  .badge a { color:var(--muted); text-decoration:none; font-size:11px; letter-spacing:.02em; }

  @media print {
    body { background:#fff; }
    .page { box-shadow:none; margin:0; max-width:none; border-radius:0; padding:32px; }
    .actions { display:none !important; }
  }
  @media (max-width:600px) {
    .page { padding:28px 22px; }
    .head, .parties { flex-direction:column; }
    .title { font-size:34px; text-align:left; }
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

    <div class="title">TAX INVOICE</div>

    <section class="parties">
      <div class="to">
        <div class="label">Bill to</div>
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
        ${paidRows}
      </tbody></table>
    </div>

    <section class="terms">
      <h2>Payment</h2>
      ${termsHtml}
    </section>

    ${paidBanner}
    ${actionsHtml}

    <div class="footer"><a href="${esc(data.appUrl)}">Powered by Snapceipt — snap receipts, send quotes &amp; invoices</a></div>
    <div class="badge"><a href="${esc(data.appUrl)}">Made with Snapceipt</a></div>
  </div>
</body>
</html>`;
}
