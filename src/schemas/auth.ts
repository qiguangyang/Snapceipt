import { z } from "zod";

/** Auth request bodies. See backend.md §1 AUTH. */

/** POST /auth/apple — verified server-side against Apple JWKS (Task: auth). */
export const appleBody = z.object({
  identityToken: z.string().min(1),
  authorizationCode: z.string().min(1),
  rawNonce: z.string().min(1),
  fullName: z.string().optional(),
  email: z.string().email().optional(),
});

export type AppleBody = z.infer<typeof appleBody>;

/** POST /auth/magic-link/request — always 202 (no enumeration); rate-limited.
 *  `.trim()` tolerates trailing whitespace; the route lowercases for storage. */
export const magicLinkRequestBody = z.object({
  email: z.string().trim().email(),
});

export type MagicLinkRequestBody = z.infer<typeof magicLinkRequestBody>;

/** POST /auth/magic-link/verify — single-use token. */
export const magicLinkVerifyBody = z.object({
  token: z.string().min(1),
});

export type MagicLinkVerifyBody = z.infer<typeof magicLinkVerifyBody>;

/** POST /auth/refresh — opaque refresh token, rotated on every use. */
export const refreshBody = z.object({
  refreshToken: z.string().min(1),
});

export type RefreshBody = z.infer<typeof refreshBody>;
