import { Hono, type Context } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { verifyInvoiceLinkToken } from "../lib/exportToken";
import { renderInvoiceHtml } from "../lib/invoiceHtml";
import { loadInvoiceForRender } from "./invoices";

/**
 * PUBLIC GET /i/:token — the hosted HTML tax-invoice page (mirrors /q/:token). Verifies the
 * signed 30-day invoice-link token (iid + uid + version), loads + tenant-scopes the invoice,
 * recomputes totals at the snapshotted gst_rate_bp, and renders the self-contained HTML (logo
 * inlined as a data-URI). A bad/expired/revoked token is 403; a valid token whose invoice no
 * longer exists (or has no line items) is 404. In PUBLIC_PATHS — no bearer required. There is
 * NO accept action: an invoice is a demand for payment, not an offer to be accepted.
 */
export const invoiceLinkRoutes = new Hono<AppEnv>();

/** Verify the invoice-link token + the revocation (link_version) gate. Throws an ApiError
 *  (403 forged/expired/revoked, 404 missing) on any failure; returns the ids on success.
 *  A legacy token (no `v` claim) verifies as version 0 and stays valid while the invoice's
 *  link_version is still 0 (the default) — so existing in-the-wild links keep working. */
async function verifyAndGate(
  c: Context<AppEnv>,
): Promise<{ invoiceId: string; userId: string }> {
  const token = c.req.param("token") ?? "";
  let invoiceId: string;
  let userId: string;
  let version: number;
  try {
    ({ invoiceId, userId, version } = await verifyInvoiceLinkToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired invoice link");
  }
  const versionRow = await c.env.DB.prepare(
    "SELECT link_version FROM invoices WHERE id = ? AND user_id = ? AND deleted_at IS NULL",
  ).bind(invoiceId, userId).first<{ link_version: number }>();
  if (!versionRow) throw new ApiError("NOT_FOUND", "Invoice not found");
  if (versionRow.link_version !== version) {
    throw new ApiError("FORBIDDEN", "This invoice link has been revoked");
  }
  return { invoiceId, userId };
}

invoiceLinkRoutes.get("/:token", async (c) => {
  const { invoiceId, userId } = await verifyAndGate(c);

  const data = await loadInvoiceForRender(c.env, invoiceId, userId);
  if (!data) throw new ApiError("NOT_FOUND", "Invoice not found");

  return new Response(renderInvoiceHtml(data), {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
});
