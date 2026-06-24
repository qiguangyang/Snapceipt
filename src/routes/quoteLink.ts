import { Hono, type Context } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { verifyQuoteLinkToken } from "../lib/exportToken";
import { renderQuoteHtml } from "../lib/quoteHtml";
import { loadQuoteForRender } from "./quotes";
import { nowMs } from "../lib/time";

/**
 * PUBLIC GET  /q/:token         — the hosted HTML quote page (spec §4). Verifies the signed
 *   30-day quote-link token (qid + uid + version), loads + tenant-scopes the quote, recomputes
 *   totals at the quote's snapshotted gst_rate_bp, and renders the self-contained HTML
 *   (logo inlined as a data-URI). A bad/expired token is 403; a valid token whose quote
 *   no longer exists (or has no line items) is 404. In PUBLIC_PATHS — no bearer required.
 * PUBLIC POST /q/:token/accept  — the client accepts the quote (spec §3). Same token verify
 *   + revocation check; sets status='accepted' (idempotent), bumps rev for sync.
 */
export const quoteLinkRoutes = new Hono<AppEnv>();

/** Verify the quote-link token + the revocation (link_version) gate. Throws an ApiError
 *  (403 forged/expired/revoked, 404 missing) on any failure; returns the ids on success. */
async function verifyAndGate(
  c: Context<AppEnv>,
): Promise<{ quoteId: string; userId: string }> {
  const token = c.req.param("token") ?? "";
  let quoteId: string;
  let userId: string;
  let version: number;
  try {
    ({ quoteId, userId, version } = await verifyQuoteLinkToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired quote link");
  }
  const versionRow = await c.env.DB.prepare(
    "SELECT link_version FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
  ).bind(quoteId, userId).first<{ link_version: number }>();
  if (!versionRow) throw new ApiError("NOT_FOUND", "Quote not found");
  if (versionRow.link_version !== version) {
    throw new ApiError("FORBIDDEN", "This quote link has been revoked");
  }
  return { quoteId, userId };
}

quoteLinkRoutes.get("/:token", async (c) => {
  const { quoteId, userId } = await verifyAndGate(c);

  const data = await loadQuoteForRender(c.env, quoteId, userId);
  if (!data) throw new ApiError("NOT_FOUND", "Quote not found");

  // Inject the verified token so the page can render the Accept button + POST the accept.
  data.token = c.req.param("token");

  return new Response(renderQuoteHtml(data), {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
});

// PUBLIC POST /q/:token/accept — the client accepts the quote (spec §3). Verifies the SAME
// signed token + revocation gate as GET /q/:token. Sets status='accepted', updated_at=now,
// bumps rev (so the owner's app pulls "Accepted" via the existing quote sync). Idempotent:
// an already-accepted quote returns ok without re-bumping. accepted_at is NOT set (no such
// column on the quotes table).
quoteLinkRoutes.post("/:token/accept", async (c) => {
  const { quoteId, userId } = await verifyAndGate(c);

  const row = await c.env.DB.prepare(
    "SELECT status FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
  ).bind(quoteId, userId).first<{ status: string }>();
  if (!row) throw new ApiError("NOT_FOUND", "Quote not found");

  if (row.status !== "accepted") {
    await c.env.DB.prepare(
      `UPDATE quotes SET status = 'accepted', updated_at = ?, rev = rev + 1
         WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
    ).bind(nowMs(), quoteId, userId).run();
  }

  return c.json({ ok: true, status: "accepted" });
});
