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
