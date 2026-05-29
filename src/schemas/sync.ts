import { z } from "zod";
import { baseEnvelope } from "./entities";

/**
 * Sync wire schemas + the composite-keyset cursor codec.
 * Cursor = base64url of { ts: lastUpdatedAt, id: lastId } so pull is stable
 * under concurrent writes (ORDER BY updatedAt, id). See backend.md §2 SYNC.
 */

/** One push mutation. payload is validated leniently here (baseEnvelope); the
 *  route picks the strict per-type schema via entitySchemaFor() at apply time. */
export const mutationSchema = z.object({
  mutationId: z.string().uuid(), // idempotency key
  entityType: z.string().min(1),
  entityId: z.string().uuid(),
  op: z.enum(["upsert", "delete"]),
  baseRev: z.number().int().nonnegative().optional(),
  updatedAt: z.number().int().nonnegative(),
  payload: baseEnvelope,
});

export type Mutation = z.infer<typeof mutationSchema>;

/** POST /sync/push body — batch capped at 200. */
export const pushBodySchema = z.object({
  deviceId: z.string().uuid(),
  mutations: z.array(mutationSchema).min(1).max(200),
});

export type PushBody = z.infer<typeof pushBodySchema>;

/** GET /sync/pull query — cursor optional (omit on first/full sync), limit 1..500. */
export const pullQuerySchema = z.object({
  cursor: z.string().min(1).optional(),
  limit: z.coerce.number().int().min(1).max(500).default(500),
});

export type PullQuery = z.infer<typeof pullQuerySchema>;

// ---- cursor codec (composite keyset) ----

export type Cursor = {
  ts: number; // lastUpdatedAt (epoch ms)
  id: string; // lastId (UUIDv7)
};

const cursorShape = z.object({
  ts: z.number().int().nonnegative(),
  id: z.string().uuid(),
});

/** base64url-encode a cursor (no padding, URL-safe). Workers runtime has btoa. */
export function encodeCursor(c: Cursor): string {
  const json = JSON.stringify({ ts: c.ts, id: c.id });
  return btoa(json).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Decode a cursor; returns null on any malformed/invalid input (caller treats as full sync). */
export function decodeCursor(raw: string | undefined | null): Cursor | null {
  if (!raw) return null;
  try {
    let b64 = raw.replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4 !== 0) b64 += "=";
    const parsed = JSON.parse(atob(b64));
    const r = cursorShape.safeParse(parsed);
    return r.success ? r.data : null;
  } catch {
    return null;
  }
}
