import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { verifyInvoiceLinkToken } from "../lib/exportToken";
import { renderInvoiceHtml } from "../lib/invoiceHtml";
import { loadInvoiceForRender } from "./invoices";

/**
 * PUBLIC GET /i/:token — the hosted HTML tax-invoice page (mirrors /q/:token). Verifies the
 * signed 30-day invoice-link token (iid + uid), loads + tenant-scopes the invoice, recomputes
 * totals at the snapshotted gst_rate_bp, and renders the self-contained HTML (logo inlined as a
 * data-URI). A bad/expired token is 403; a valid token whose invoice no longer exists (or has
 * no line items) is 404. In PUBLIC_PATHS — no bearer required. There is NO accept action: an
 * invoice is a demand for payment, not an offer to be accepted.
 */
export const invoiceLinkRoutes = new Hono<AppEnv>();

invoiceLinkRoutes.get("/:token", async (c) => {
  const token = c.req.param("token") ?? "";
  let invoiceId: string;
  let userId: string;
  try {
    ({ invoiceId, userId } = await verifyInvoiceLinkToken(c.env.JWT_SIGNING_KEY, token));
  } catch {
    throw new ApiError("FORBIDDEN", "Invalid or expired invoice link");
  }

  const data = await loadInvoiceForRender(c.env, invoiceId, userId);
  if (!data) throw new ApiError("NOT_FOUND", "Invoice not found");

  return new Response(renderInvoiceHtml(data), {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
});
