import type { Env } from "../env";

/**
 * Thin wrapper around the Cloudflare SendEmail binding. Isolating the actual
 * `env.EMAIL.send` call here lets tests spy on / stub this function with
 * `vi.spyOn(emailModule, "sendMagicLinkEmail")` — the real binding is not
 * exercisable in the vitest-pool-workers runtime (same constraint as the AI
 * binding), so route tests assert against this seam instead of a live send.
 */

const MAGIC_LINK_SENDER = "noreply@snapceipt.app";

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
  const { createMimeMessage } = await import("mimetext/browser");
  const { EmailMessage } = await import("cloudflare:email");

  const mime = createMimeMessage();
  mime.setSender({ name: "Snapceipt", addr: MAGIC_LINK_SENDER });
  mime.setRecipient(msg.to);
  mime.setHeader("Reply-To", msg.replyTo);
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
