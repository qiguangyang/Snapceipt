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
}

/**
 * Send the quote email with a LINK to the hosted HTML quote (spec §4/§5 — no PDF
 * attachment). Mirrors sendMagicLinkEmail's plain-text SendEmail builder path (no
 * mimetext/cloudflare:email needed for a link-only message). `from` is the magic-link
 * sender; Reply-To is the trader so the client replies to them. Stubbed in route tests
 * via vi.spyOn(emailModule, "sendQuoteEmail").
 */
export async function sendQuoteEmail(env: Env, msg: QuoteEmail): Promise<void> {
  const total = `$${(msg.totalCents / 100).toFixed(2)}`;
  const greeting = msg.clientName ? `Hi ${msg.clientName},` : "Hi,";
  await env.EMAIL.send({
    from: { name: "Snapceipt", email: MAGIC_LINK_SENDER },
    to: msg.to,
    replyTo: msg.replyTo,
    subject: `Quote ${msg.quoteNumber} — ${total}`,
    text:
      `${greeting}\n\n` +
      `View your quote ${msg.quoteNumber} for ${total} here:\n\n${msg.url}\n\n` +
      `Reply to this email if you have any questions.\n`,
  });
}

/** The invoice-send email (tax-invoice PDF attachment). */
export interface InvoiceEmail {
  to: string;
  /** The trader's own email — set as Reply-To so the client replies to them. */
  replyTo: string;
  invoiceNumber: string;
  clientName: string | null;
  totalCents: number;
  pdf: Uint8Array;
}

/** PDF attachment ceiling — Cloudflare Email Send caps the message. */
const MAX_INVOICE_PDF_BYTES = 25 * 1024 * 1024; // 25 MiB

/**
 * Send the invoice email with the tax-invoice PDF attached (spec §4.5). Mirrors
 * sendQuoteEmail: mimetext/browser MIME (self-contained, workerd-safe), base64 PDF
 * attachment, cloudflare:email EmailMessage(from,to,raw) + env.EMAIL.send. `from` is
 * the magic-link sender (the only allowed_sender_addresses entry); Reply-To is the
 * trader so the client replies to them. Stubbed in route tests via
 * vi.spyOn(emailModule, "sendInvoiceEmail").
 */
export async function sendInvoiceEmail(env: Env, msg: InvoiceEmail): Promise<void> {
  if (msg.pdf.byteLength > MAX_INVOICE_PDF_BYTES) {
    throw new Error(`invoice PDF exceeds ${MAX_INVOICE_PDF_BYTES} bytes`);
  }

  const { createMimeMessage, Mailbox } = await import("mimetext/browser");
  const { EmailMessage } = await import("cloudflare:email");

  const total = `$${(msg.totalCents / 100).toFixed(2)}`;
  const greeting = msg.clientName ? `Hi ${msg.clientName},` : "Hi,";

  const mime = createMimeMessage();
  mime.setSender({ name: "Snapceipt", addr: MAGIC_LINK_SENDER });
  mime.setRecipient(msg.to);
  mime.setHeader("Reply-To", new Mailbox(msg.replyTo, { type: "Reply-To" } as any));
  mime.setSubject(`Tax invoice ${msg.invoiceNumber} — ${total}`);
  mime.addMessage({
    contentType: "text/plain",
    data:
      `${greeting}\n\n` +
      `Please find attached tax invoice ${msg.invoiceNumber} for ${total}.\n\n` +
      `Reply to this email if you have any questions.\n`,
  });
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
