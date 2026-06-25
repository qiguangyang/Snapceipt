import type { Env } from "../env";

/**
 * Thin wrapper around the Cloudflare SendEmail binding. Isolating the actual
 * `env.EMAIL.send` call here lets tests spy on / stub this function with
 * `vi.spyOn(emailModule, "sendMagicLinkEmail")` — the real binding is not
 * exercisable in the vitest-pool-workers runtime (same constraint as the AI
 * binding), so route tests assert against this seam instead of a live send.
 */

const MAGIC_LINK_SENDER = "noreply@snapceipt.cc";

export interface MagicLinkEmail {
  to: string;
  /** The fully-formed universal link carrying `?token=<token>`. */
  link: string;
}

/**
 * Send the magic-link sign-in email via the SendEmail builder overload (no
 * mimetext / cloudflare:email module required). Returns nothing; failures
 * surface as a thrown error to the caller.
 */
export async function sendMagicLinkEmail(env: Env, msg: MagicLinkEmail): Promise<void> {
  await env.EMAIL.send({
    from: { name: "Snapceipt", email: MAGIC_LINK_SENDER },
    to: msg.to,
    subject: "Your Snapceipt sign-in link",
    text:
      `Tap to sign in to Snapceipt:\n\n${msg.link}\n\n` +
      `This link expires in 10 minutes and can be used once. ` +
      `If you didn't request it, ignore this email.`,
  });
}

export interface EmailChangeCode {
  to: string;
  code: string;
}

/**
 * Send the 6-digit email-change confirmation code via the SendEmail builder
 * overload (same path as sendMagicLinkEmail). Failures surface as a thrown error.
 */
export async function sendEmailChangeCode(env: Env, msg: EmailChangeCode): Promise<void> {
  await env.EMAIL.send({
    from: { name: "Snapceipt", email: MAGIC_LINK_SENDER },
    to: msg.to,
    subject: "Confirm your new Snapceipt email",
    text:
      `Your Snapceipt email-change code is: ${msg.code}\n\n` +
      `Enter it in the app to confirm. It expires in 10 minutes and can be used once. ` +
      `If you didn't request this, ignore this email.`,
  });
}

export interface SignInCode {
  to: string;
  code: string;
}

/**
 * Send the 6-digit sign-in OTP (the cross-device fallback for the device-bound
 * magic link). Same SendEmail builder path as sendMagicLinkEmail; spy-able via
 * vi.spyOn(emailModule, "sendSignInCode"). Failures surface as a thrown error.
 */
export async function sendSignInCode(env: Env, msg: SignInCode): Promise<void> {
  await env.EMAIL.send({
    from: { name: "Snapceipt", email: MAGIC_LINK_SENDER },
    to: msg.to,
    subject: "Your Snapceipt sign-in code",
    text:
      `Your Snapceipt sign-in code is: ${msg.code}\n\n` +
      `Enter it in the app to sign in. It expires in 10 minutes and can be used once. ` +
      `If you didn't request this, ignore this email.`,
  });
}

/** The accountant export email (CSV + PDF attachments). */
export interface ExportEmail {
  to: string;
  /** The user's own email — set as Reply-To so the accountant replies to them. */
  replyTo: string;
  profileName: string;
  periodLabel: string;
  csv: string;
  pdf: Uint8Array;
}

/** Total attachment ceiling (CSV + PDF) — Cloudflare Email Send caps the message. */
const MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024; // 25 MiB

/**
 * Send the accountant tax-pack email with the CSV + PDF attached. Builds a MIME
 * message via mimetext (pure-JS) and sends it through the cloudflare:email
 * EmailMessage(from,to,raw) constructor + env.EMAIL.send. `from` is the
 * magic-link sender (the only allowed_sender_addresses entry). Stubbed in tests
 * via vi.spyOn(emailModule, "sendExportEmail"), exactly like sendMagicLinkEmail.
 */
export async function sendExportEmail(env: Env, msg: ExportEmail): Promise<void> {
  const csvBytes = new TextEncoder().encode(msg.csv);
  const total = csvBytes.byteLength + msg.pdf.byteLength;
  if (total > MAX_ATTACHMENT_BYTES) {
    throw new Error(`export attachments exceed ${MAX_ATTACHMENT_BYTES} bytes`);
  }

  // Lazy dynamic imports so the test runtime never needs to resolve the
  // cloudflare:email module at module-load (it is only resolvable inside workerd).
  // Use mimetext's BROWSER entrypoint: it is self-contained (its own Base64 + "\n"
  // EOL) with NO Node `os`/`mime-types` imports, so it bundles cleanly in workerd —
  // the default "mimetext" (node) entrypoint does `import { EOL } from "os"` +
  // `import * as o from "mime-types"`, which is unnecessary baggage under workerd.
  const { createMimeMessage, Mailbox } = await import("mimetext/browser");
  const { EmailMessage } = await import("cloudflare:email");

  const mime = createMimeMessage();
  mime.setSender({ name: "Snapceipt", addr: MAGIC_LINK_SENDER });
  mime.setRecipient(msg.to);
  // mimetext's built-in Reply-To field expects a Mailbox instance (it
  // validates via validateMailboxSingle), so we construct one explicitly.
  mime.setHeader("Reply-To", new Mailbox(msg.replyTo, { type: "Reply-To" } as any));
  mime.setSubject(`Snapceipt export — ${msg.profileName} — ${msg.periodLabel}`);
  mime.addMessage({
    contentType: "text/plain",
    data:
      `Attached is the Snapceipt export for ${msg.profileName} (${msg.periodLabel}).\n\n` +
      `Files: a bookkeeping CSV and a one-page summary PDF.\n`,
  });
  // mimetext defaults attachments to Content-Transfer-Encoding: base64, but we
  // set `encoding` explicitly so the pre-encoded base64 `data` is never re-encoded.
  // base64Bytes() chunks the input so a large PDF can't blow the call stack via a
  // String.fromCharCode(...bigArray) spread.
  mime.addAttachment({
    filename: "snapceipt-export.csv",
    contentType: "text/csv",
    encoding: "base64",
    data: base64Bytes(csvBytes),
  });
  mime.addAttachment({
    filename: "snapceipt-summary.pdf",
    contentType: "application/pdf",
    encoding: "base64",
    data: base64Bytes(msg.pdf),
  });

  const message = new EmailMessage(MAGIC_LINK_SENDER, msg.to, mime.asRaw());
  await env.EMAIL.send(message);
}

/** One line item rendered in the quote email body. */
export interface QuoteEmailLineItem {
  description: string;
  quantity: number;
  /** Line amount in cents = quantity × unitPriceCents. */
  amountCents: number;
}

/** The trader's business identity shown in the quote email header/footer. */
export interface QuoteEmailBusiness {
  name: string;
  /** R2 object key of the logo (rendered as https://api.snapceipt.cc/images/<key>); null ⇒ no logo. */
  logoR2Key: string | null;
  abn: string | null;
  /** Best contact line for the trader (email/phone), shown under the business name. */
  contact: string | null;
}

/** The quote-send email (a link to the hosted HTML quote, no attachment). */
export interface QuoteEmail {
  to: string;
  /** The trader's own email — set as Reply-To so the client replies to them. */
  replyTo: string;
  quoteNumber: string;
  clientName: string | null;
  totalCents: number;
  /** The hosted HTML quote URL (https://api.snapceipt.cc/q/<token>). */
  url: string;
  /** The trader's business identity (name/logo/abn/contact). */
  business: QuoteEmailBusiness;
  /** Line items for the email body table. */
  lineItems: QuoteEmailLineItem[];
  subtotalCents: number;
  gstCents: number;
  /** True when GST applies (shows the GST row). */
  gstEnabled: boolean;
  /** YYYY-MM-DD valid-until date, or null. */
  validUntil: string | null;
  /** App/site link for the marketing footer (https://snapceipt.cc). */
  appUrl: string;
}

/** Origin that serves business logos from R2: GET /images/<r2key>. */
const IMAGE_ORIGIN = "https://api.snapceipt.cc";

/** Dollars with a leading sign, e.g. "$40.00". */
function emailDollars(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

/** HTML-escape a string (text + attribute safe). null/undefined ⇒ "". */
function emailEsc(s: string | null | undefined): string {
  if (s == null) return "";
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Build the EMAIL-SAFE rich HTML body for the quote email: table-based layout, inline
 * CSS only (Gmail/Outlook strip <style>/flex/grid), ~600px max width, logo via an
 * <img src> pointing at the R2 image URL (NOT a data-URI — email clients block those).
 */
function renderQuoteEmailHtml(msg: QuoteEmail): string {
  const b = msg.business;
  const greeting = msg.clientName ? `Hi ${emailEsc(msg.clientName)},` : "Hi,";
  const total = emailDollars(msg.totalCents);

  const logoImg = b.logoR2Key
    ? `<img src="${IMAGE_ORIGIN}/images/${emailEsc(b.logoR2Key)}" alt="${emailEsc(b.name)} logo" height="48" style="max-height:48px;max-width:180px;display:block;border:0;outline:none;">`
    : "";

  const businessSub: string[] = [];
  if (b.contact) businessSub.push(emailEsc(b.contact));
  if (b.abn) businessSub.push(`ABN ${emailEsc(b.abn)}`);
  const businessSubHtml = businessSub
    .map((l) => `<div style="font-size:13px;color:#6b7280;line-height:1.5;">${l}</div>`)
    .join("");

  const itemRows = msg.lineItems
    .map(
      (li) => `
            <tr>
              <td style="padding:10px 8px;border-bottom:1px solid #eceeec;font-size:14px;color:#1f2937;text-align:left;">${li.quantity}</td>
              <td style="padding:10px 8px;border-bottom:1px solid #eceeec;font-size:14px;color:#1f2937;text-align:left;">${emailEsc(li.description)}</td>
              <td style="padding:10px 8px;border-bottom:1px solid #eceeec;font-size:14px;color:#1f2937;text-align:right;white-space:nowrap;">${emailDollars(li.amountCents)}</td>
            </tr>`,
    )
    .join("");

  const gstRow = msg.gstEnabled
    ? `
            <tr>
              <td style="padding:4px 8px;font-size:14px;color:#6b7280;text-align:right;">GST</td>
              <td style="padding:4px 8px;font-size:14px;color:#1f2937;text-align:right;white-space:nowrap;">${emailDollars(msg.gstCents)}</td>
            </tr>`
    : "";

  const validUntilRow = msg.validUntil
    ? `<div style="font-size:13px;color:#6b7280;margin:18px 0 0;">Valid until ${emailEsc(msg.validUntil)}.</div>`
    : "";

  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#eceeec;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eceeec;">
    <tr>
      <td align="center" style="padding:24px 12px;">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;background:#ffffff;border-radius:8px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
          <tr>
            <td style="padding:32px 32px 0;">
              ${logoImg}
              <div style="font-size:20px;font-weight:700;color:#1f2937;margin:${logoImg ? "12px" : "0"} 0 4px;">${emailEsc(b.name)}</div>
              ${businessSubHtml}
            </td>
          </tr>
          <tr>
            <td style="padding:24px 32px 0;">
              <div style="font-size:24px;font-weight:800;letter-spacing:.06em;color:#4f7a63;">Quote ${emailEsc(msg.quoteNumber)}</div>
              <div style="font-size:15px;color:#1f2937;margin:16px 0 0;">${greeting}</div>
              <div style="font-size:15px;color:#1f2937;margin:8px 0 0;line-height:1.55;">Here is your quote${msg.clientName ? "" : ""} for ${total}. You can view the full quote and accept it online using the button below.</div>
            </td>
          </tr>
          <tr>
            <td style="padding:20px 32px 0;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
                <tr>
                  <th style="padding:8px 8px;border-bottom:2px solid #4f7a63;font-size:12px;color:#4f7a63;text-transform:uppercase;letter-spacing:.04em;text-align:left;">Qty</th>
                  <th style="padding:8px 8px;border-bottom:2px solid #4f7a63;font-size:12px;color:#4f7a63;text-transform:uppercase;letter-spacing:.04em;text-align:left;">Description</th>
                  <th style="padding:8px 8px;border-bottom:2px solid #4f7a63;font-size:12px;color:#4f7a63;text-transform:uppercase;letter-spacing:.04em;text-align:right;">Amount</th>
                </tr>${itemRows}
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding:8px 32px 0;">
              <table role="presentation" align="right" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
                <tr>
                  <td style="padding:4px 8px;font-size:14px;color:#6b7280;text-align:right;">Subtotal</td>
                  <td style="padding:4px 8px;font-size:14px;color:#1f2937;text-align:right;white-space:nowrap;">${emailDollars(msg.subtotalCents)}</td>
                </tr>${gstRow}
                <tr>
                  <td style="padding:8px 8px;font-size:16px;font-weight:700;color:#4f7a63;text-align:right;border-top:1px solid #4f7a63;">Total (AUD)</td>
                  <td style="padding:8px 8px;font-size:16px;font-weight:700;color:#4f7a63;text-align:right;white-space:nowrap;border-top:1px solid #4f7a63;">${total}</td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding:24px 32px 0;">
              <table role="presentation" cellpadding="0" cellspacing="0"><tr>
                <td align="center" style="border-radius:6px;background:#4f7a63;">
                  <a href="${emailEsc(msg.url)}" style="display:inline-block;padding:14px 28px;font-size:16px;font-weight:700;color:#ffffff;text-decoration:none;border-radius:6px;">View &amp; accept online &rarr;</a>
                </td>
              </tr></table>
              ${validUntilRow}
              <div style="font-size:13px;color:#6b7280;margin:18px 0 0;">Reply to this email if you have any questions.</div>
            </td>
          </tr>
          <tr>
            <td style="padding:28px 32px 32px;">
              <div style="border-top:1px solid #eceeec;padding-top:16px;text-align:center;">
                <a href="${emailEsc(msg.appUrl)}" style="font-size:12px;color:#9ca3af;text-decoration:none;">Powered by Snapceipt — snap receipts, send quotes &amp; invoices</a>
              </div>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

/** The plain-text fallback for non-HTML clients (keeps the link working). */
function renderQuoteEmailText(msg: QuoteEmail): string {
  const total = emailDollars(msg.totalCents);
  const greeting = msg.clientName ? `Hi ${msg.clientName},` : "Hi,";
  const validUntil = msg.validUntil ? `Valid until ${msg.validUntil}.\n\n` : "";
  return (
    `${greeting}\n\n` +
    `Here is your quote ${msg.quoteNumber} from ${msg.business.name} for ${total}.\n\n` +
    `View & accept it online here:\n\n${msg.url}\n\n` +
    validUntil +
    `Reply to this email if you have any questions.\n\n` +
    `— Powered by Snapceipt: snap receipts, send quotes & invoices. ${msg.appUrl}\n`
  );
}

/**
 * Send the quote email with a LINK to the hosted HTML quote (spec §4/§5 — no PDF
 * attachment). Uses the SendEmail builder overload's `html` + `text` fields (no
 * mimetext/cloudflare:email needed for a link-only message): rich HTML body for HTML
 * clients, plain-text fallback for the rest. `from` is the magic-link sender; Reply-To
 * is the trader so the client replies to them. Stubbed in route tests via
 * vi.spyOn(emailModule, "sendQuoteEmail").
 */
export async function sendQuoteEmail(env: Env, msg: QuoteEmail): Promise<void> {
  const businessName = msg.business.name.trim();
  const subject = businessName
    ? `Your quote from ${businessName}`
    : `Your quote ${msg.quoteNumber}`;
  await env.EMAIL.send({
    from: { name: "Snapceipt", email: MAGIC_LINK_SENDER },
    to: msg.to,
    replyTo: msg.replyTo,
    subject,
    text: renderQuoteEmailText(msg),
    html: renderQuoteEmailHtml(msg),
  });
}

/** The invoice-send email: a quote-style HTML body + a link to the hosted invoice page,
 *  with the tax-invoice PDF attached. */
export interface InvoiceEmail {
  to: string;
  /** The trader's own/business email — set as Reply-To so the client replies to them. */
  replyTo: string;
  invoiceNumber: string;
  clientName: string | null;
  totalCents: number;
  /** The hosted HTML invoice URL (https://api.snapceipt.cc/i/<token>). */
  url: string;
  business: QuoteEmailBusiness;
  lineItems: QuoteEmailLineItem[];
  subtotalCents: number;
  gstCents: number;
  /** True when GST applies (shows the GST row). */
  gstEnabled: boolean;
  /** YYYY-MM-DD due date, or null. */
  dueDate: string | null;
  /** App/site link for the marketing footer (https://snapceipt.cc). */
  appUrl: string;
  /** The tax-invoice PDF to attach. */
  pdf: Uint8Array;
}

/** PDF attachment ceiling — Cloudflare Email Send caps the message. */
const MAX_INVOICE_PDF_BYTES = 25 * 1024 * 1024; // 25 MiB

/**
 * Build the EMAIL-SAFE rich HTML body for the invoice email (mirrors renderQuoteEmailHtml):
 * table-based layout, inline CSS only, ~600px wide, logo via an <img src> at the R2 image URL.
 */
function renderInvoiceEmailHtml(msg: InvoiceEmail): string {
  const b = msg.business;
  const greeting = msg.clientName ? `Hi ${emailEsc(msg.clientName)},` : "Hi,";
  const total = emailDollars(msg.totalCents);

  const logoImg = b.logoR2Key
    ? `<img src="${IMAGE_ORIGIN}/images/${emailEsc(b.logoR2Key)}" alt="${emailEsc(b.name)} logo" height="48" style="max-height:48px;max-width:180px;display:block;border:0;outline:none;">`
    : "";

  const businessSub: string[] = [];
  if (b.contact) businessSub.push(emailEsc(b.contact));
  if (b.abn) businessSub.push(`ABN ${emailEsc(b.abn)}`);
  const businessSubHtml = businessSub
    .map((l) => `<div style="font-size:13px;color:#6b7280;line-height:1.5;">${l}</div>`)
    .join("");

  const itemRows = msg.lineItems
    .map(
      (li) => `
            <tr>
              <td style="padding:10px 8px;border-bottom:1px solid #eceeec;font-size:14px;color:#1f2937;text-align:left;">${li.quantity}</td>
              <td style="padding:10px 8px;border-bottom:1px solid #eceeec;font-size:14px;color:#1f2937;text-align:left;">${emailEsc(li.description)}</td>
              <td style="padding:10px 8px;border-bottom:1px solid #eceeec;font-size:14px;color:#1f2937;text-align:right;white-space:nowrap;">${emailDollars(li.amountCents)}</td>
            </tr>`,
    )
    .join("");

  const gstRow = msg.gstEnabled
    ? `
            <tr>
              <td style="padding:4px 8px;font-size:14px;color:#6b7280;text-align:right;">GST</td>
              <td style="padding:4px 8px;font-size:14px;color:#1f2937;text-align:right;white-space:nowrap;">${emailDollars(msg.gstCents)}</td>
            </tr>`
    : "";

  const dueRow = msg.dueDate
    ? `<div style="font-size:13px;color:#6b7280;margin:18px 0 0;">Payment due by ${emailEsc(msg.dueDate)}.</div>`
    : "";

  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#eceeec;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eceeec;">
    <tr>
      <td align="center" style="padding:24px 12px;">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;background:#ffffff;border-radius:8px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
          <tr>
            <td style="padding:32px 32px 0;">
              ${logoImg}
              <div style="font-size:20px;font-weight:700;color:#1f2937;margin:${logoImg ? "12px" : "0"} 0 4px;">${emailEsc(b.name)}</div>
              ${businessSubHtml}
            </td>
          </tr>
          <tr>
            <td style="padding:24px 32px 0;">
              <div style="font-size:24px;font-weight:800;letter-spacing:.06em;color:#4f7a63;">Tax invoice ${emailEsc(msg.invoiceNumber)}</div>
              <div style="font-size:15px;color:#1f2937;margin:16px 0 0;">${greeting}</div>
              <div style="font-size:15px;color:#1f2937;margin:8px 0 0;line-height:1.55;">Here is your tax invoice for ${total}. You can view it online and download a PDF using the button below — the PDF is also attached to this email.</div>
            </td>
          </tr>
          <tr>
            <td style="padding:20px 32px 0;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
                <tr>
                  <th style="padding:8px 8px;border-bottom:2px solid #4f7a63;font-size:12px;color:#4f7a63;text-transform:uppercase;letter-spacing:.04em;text-align:left;">Qty</th>
                  <th style="padding:8px 8px;border-bottom:2px solid #4f7a63;font-size:12px;color:#4f7a63;text-transform:uppercase;letter-spacing:.04em;text-align:left;">Description</th>
                  <th style="padding:8px 8px;border-bottom:2px solid #4f7a63;font-size:12px;color:#4f7a63;text-transform:uppercase;letter-spacing:.04em;text-align:right;">Amount</th>
                </tr>${itemRows}
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding:8px 32px 0;">
              <table role="presentation" align="right" cellpadding="0" cellspacing="0" style="border-collapse:collapse;">
                <tr>
                  <td style="padding:4px 8px;font-size:14px;color:#6b7280;text-align:right;">Subtotal</td>
                  <td style="padding:4px 8px;font-size:14px;color:#1f2937;text-align:right;white-space:nowrap;">${emailDollars(msg.subtotalCents)}</td>
                </tr>${gstRow}
                <tr>
                  <td style="padding:8px 8px;font-size:16px;font-weight:700;color:#4f7a63;text-align:right;border-top:1px solid #4f7a63;">Total (AUD)</td>
                  <td style="padding:8px 8px;font-size:16px;font-weight:700;color:#4f7a63;text-align:right;white-space:nowrap;border-top:1px solid #4f7a63;">${total}</td>
                </tr>
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding:24px 32px 0;">
              <table role="presentation" cellpadding="0" cellspacing="0"><tr>
                <td align="center" style="border-radius:6px;background:#4f7a63;">
                  <a href="${emailEsc(msg.url)}" style="display:inline-block;padding:14px 28px;font-size:16px;font-weight:700;color:#ffffff;text-decoration:none;border-radius:6px;">View invoice online &rarr;</a>
                </td>
              </tr></table>
              ${dueRow}
              <div style="font-size:13px;color:#6b7280;margin:18px 0 0;">Reply to this email if you have any questions.</div>
            </td>
          </tr>
          <tr>
            <td style="padding:28px 32px 32px;">
              <div style="border-top:1px solid #eceeec;padding-top:16px;text-align:center;">
                <a href="${emailEsc(msg.appUrl)}" style="font-size:12px;color:#9ca3af;text-decoration:none;">Powered by Snapceipt — snap receipts, send quotes &amp; invoices</a>
              </div>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

/** The plain-text fallback for non-HTML clients (keeps the link working). */
function renderInvoiceEmailText(msg: InvoiceEmail): string {
  const total = emailDollars(msg.totalCents);
  const greeting = msg.clientName ? `Hi ${msg.clientName},` : "Hi,";
  const due = msg.dueDate ? `Payment due by ${msg.dueDate}.\n\n` : "";
  return (
    `${greeting}\n\n` +
    `Here is your tax invoice ${msg.invoiceNumber} from ${msg.business.name} for ${total}.\n\n` +
    `View it online here:\n\n${msg.url}\n\n` +
    `The PDF is attached to this email.\n\n` +
    due +
    `Reply to this email if you have any questions.\n\n` +
    `— Powered by Snapceipt: snap receipts, send quotes & invoices. ${msg.appUrl}\n`
  );
}

/**
 * Send the invoice email: quote-style HTML body + plain-text fallback + a link to the hosted
 * invoice page, with the tax-invoice PDF attached. Uses mimetext/browser (self-contained,
 * workerd-safe) so a multipart message (HTML + text + attachment) can be built, then
 * cloudflare:email EmailMessage(from,to,raw) + env.EMAIL.send. `from` is the magic-link sender
 * (the only allowed_sender_addresses entry); Reply-To is the trader so the client replies to
 * them. Stubbed in route tests via vi.spyOn(emailModule, "sendInvoiceEmail").
 */
export async function sendInvoiceEmail(env: Env, msg: InvoiceEmail): Promise<void> {
  if (msg.pdf.byteLength > MAX_INVOICE_PDF_BYTES) {
    throw new Error(`invoice PDF exceeds ${MAX_INVOICE_PDF_BYTES} bytes`);
  }

  const { createMimeMessage, Mailbox } = await import("mimetext/browser");
  const { EmailMessage } = await import("cloudflare:email");

  const businessName = msg.business.name.trim();
  const subject = businessName
    ? `Your tax invoice from ${businessName}`
    : `Tax invoice ${msg.invoiceNumber}`;

  const mime = createMimeMessage();
  mime.setSender({ name: "Snapceipt", addr: MAGIC_LINK_SENDER });
  mime.setRecipient(msg.to);
  mime.setHeader("Reply-To", new Mailbox(msg.replyTo, { type: "Reply-To" } as any));
  mime.setSubject(subject);
  mime.addMessage({ contentType: "text/plain", data: renderInvoiceEmailText(msg) });
  mime.addMessage({ contentType: "text/html", data: renderInvoiceEmailHtml(msg) });
  mime.addAttachment({
    filename: `invoice-${msg.invoiceNumber}.pdf`,
    contentType: "application/pdf",
    encoding: "base64",
    data: base64Bytes(msg.pdf),
  });

  const message = new EmailMessage(MAGIC_LINK_SENDER, msg.to, mime.asRaw());
  await env.EMAIL.send(message);
}

/** Base64-encode bytes in chunks (avoids the call-stack limit of spreading a
 *  large Uint8Array into String.fromCharCode). */
function base64Bytes(bytes: Uint8Array): string {
  let binary = "";
  const CHUNK = 0x8000; // 32 KiB per fromCharCode call
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}
