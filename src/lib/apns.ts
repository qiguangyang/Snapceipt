import { SignJWT, importPKCS8 } from "jose";
import type { Env } from "../env";

/** The APNs JSON payload (spec §4.5). */
export interface ApnsPayload {
  aps: {
    alert: { title: string; body: string };
    sound: string;
  };
  budgetId: string;
  deepLink: string;
}

/** sendPush result. `stub` is true when APNS_KEY is absent (no network call made). */
export type SendPushResult = { stub: true } | { stub: false; status: number };

// Module-scoped JWT cache. APNs provider tokens are valid up to 60 min; we
// refresh at ~50 min. Caching is per-isolate and harmless across requests since
// the token only depends on the (static) team/key id + signing key.
let cachedJwt: string | null = null;
let cachedAtMs = 0;
const JWT_TTL_MS = 50 * 60 * 1000;

/**
 * Sign (or return the cached) APNs provider JWT: ES256 over { iss: TEAM, iat },
 * protected header { alg: ES256, kid: KEY_ID }. Caller must ensure env.APNS_KEY,
 * APNS_KEY_ID and APNS_TEAM_ID are present (sendPush gates on APNS_KEY first).
 */
export async function signApnsJwt(env: Env): Promise<string> {
  const now = Date.now();
  if (cachedJwt && now - cachedAtMs < JWT_TTL_MS) return cachedJwt;
  const key = await importPKCS8(env.APNS_KEY as string, "ES256");
  const jwt = await new SignJWT({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) })
    .setProtectedHeader({ alg: "ES256", kid: env.APNS_KEY_ID as string })
    .sign(key);
  cachedJwt = jwt;
  cachedAtMs = now;
  return jwt;
}

/**
 * Send one APNs alert push. GATED: when env.APNS_KEY is absent the .p8 is not
 * provisioned, so this logs and returns { stub: true } with NO network call.
 * Otherwise it POSTs to api.push.apple.com with the ES256 bearer JWT, the
 * bundle-id apns-topic, alert push-type, and priority 10.
 */
export async function sendPush(
  env: Env,
  apnsToken: string,
  payload: ApnsPayload,
): Promise<SendPushResult> {
  if (!env.APNS_KEY) {
    // Don't log the device token (a sensitive push credential); a short prefix is enough
    // to correlate in stub mode.
    console.log(`[apns:stub] would push to ${apnsToken.slice(0, 8)}…: ${payload.aps.alert.title}`);
    return { stub: true };
  }
  const jwt = await signApnsJwt(env);
  const res = await fetch(`https://api.push.apple.com/3/device/${apnsToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": env.APPLE_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify(payload),
  });
  return { stub: false, status: res.status };
}
