import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { nowMs } from "../lib/time";

/**
 * Business-profile asset routes.
 *   POST /profile/logo?profileId=<uuid> — raw image bytes (image/png|jpeg); writes to
 *   R2 at <userId>/profiles/<profileId>/logo and sets profiles.logo_r2_key. The HTML
 *   quote (GET /q/:token) later inlines this object as a data-URI. Auth-gated by the
 *   global middleware (c.var.userId is set).
 */
export const profileRoutes = new Hono<AppEnv>();

const MAX_LOGO_BYTES = 4_194_304; // 4 MiB
const ALLOWED = ["image/png", "image/jpeg"];

profileRoutes.post("/logo", async (c) => {
  const userId = c.var.userId;

  const profileId = c.req.query("profileId");
  if (!profileId) throw new ApiError("VALIDATION_FAILED", "Missing profileId");

  const contentType = (c.req.header("content-type") ?? "").split(";")[0]!.trim();
  if (!ALLOWED.includes(contentType)) {
    throw new ApiError("VALIDATION_FAILED", "Expected Content-Type: image/png or image/jpeg");
  }

  const buf = await c.req.arrayBuffer();
  if (buf.byteLength === 0) throw new ApiError("VALIDATION_FAILED", "Empty image body");
  if (buf.byteLength > MAX_LOGO_BYTES) {
    throw new ApiError("VALIDATION_FAILED", `Logo exceeds ${MAX_LOGO_BYTES} bytes`);
  }

  // Tenancy: the profile must belong to the authed user.
  const owned = await c.env.DB.prepare(
    `SELECT 1 FROM profiles WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
  ).bind(profileId, userId).first<{ 1: number }>();
  if (!owned) throw new ApiError("NOT_FOUND", "Profile not found for this user");

  const key = `${userId}/profiles/${profileId}/logo`;
  await c.env.RECEIPTS.put(key, buf, { httpMetadata: { contentType } });

  await c.env.DB.prepare(
    `UPDATE profiles SET logo_r2_key = ?, updated_at = ? WHERE id = ? AND user_id = ?`,
  ).bind(key, nowMs(), profileId, userId).run();

  return c.json({ logoR2Key: key, ok: true });
});
