import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { verifyQuoteLinkToken } from "../lib/exportToken";
import { renderQuoteHtml } from "../lib/quoteHtml";
import { loadQuoteForRender } from "./quotes";

/**
 * PUBLIC GET /q/:token — the hosted HTML quote page (spec §4). Verifies the signed
 * 30-day quote-link token (qid + uid + version), loads + tenant-scopes the quote, recomputes
 * totals at the quote's snapshotted gst_rate_bp, and renders the self-contained HTML
 * (logo inlined as a data-URI). A bad/expired token is 403; a valid token whose quote
 * no longer exists (or has no line items) is 404. In PUBLIC_PATHS — no bearer required.
 */
export const quoteLinkRoutes = new Hono<AppEnv>();

quoteLinkRoutes.get("/:token", async (c) => {
  const token = c.req.param("token");
  let quoteId: string;
  let userId: string;
  let version: number;
  try {
    ({ quoteId, userId, version } = await verifyQuoteLinkToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired quote link");
  }

  // Revocation check: serve only if the token's version matches the quote's CURRENT
  // link_version. A revoke/re-issue bumps link_version, so older links no longer resolve.
  const versionRow = await c.env.DB.prepare(
    "SELECT link_version FROM quotes WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
  ).bind(quoteId, userId).first<{ link_version: number }>();
  if (!versionRow) throw new ApiError("NOT_FOUND", "Quote not found");
  if (versionRow.link_version !== version) {
    throw new ApiError("FORBIDDEN", "This quote link has been revoked");
  }

  const data = await loadQuoteForRender(c.env, quoteId, userId);
  if (!data) throw new ApiError("NOT_FOUND", "Quote not found");

  return new Response(renderQuoteHtml(data), {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
});
