import { describe, expect, it } from "vitest";
import { decodeProtectedHeader, decodeJwt } from "jose";
import { signApnsJwt, sendPush, type ApnsPayload } from "../src/lib/apns";
import type { Env } from "../src/env";

// A throwaway ES256 PKCS8 PEM generated for tests only (never a real APNs key).
// Generated via: openssl ecparam -genkey -name prime256v1 -noout
//   | openssl pkcs8 -topk8 -nocrypt
// VERIFIED: this exact literal parses + signs via jose.importPKCS8(.,"ES256")
// + SignJWT().sign(). If a future edit changes it and it fails to parse,
// regenerate with the openssl pipeline above and paste the result.
const TEST_P8 = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----`;

function stubEnv(over: Partial<Env> = {}): Env {
  return {
    APPLE_BUNDLE_ID: "com.snapceipt.app",
    ...over,
  } as Env;
}

const PAYLOAD: ApnsPayload = {
  aps: { alert: { title: "Budget alert", body: "Meals: $90.00 of $100.00 (90%)" }, sound: "default" },
  budgetId: "b1",
  deepLink: "snapceipt://budget/b1",
};

describe("signApnsJwt", () => {
  it("produces an ES256 JWT carrying kid + iss", async () => {
    const env = stubEnv({ APNS_KEY: TEST_P8, APNS_KEY_ID: "KID123", APNS_TEAM_ID: "TEAM456" });
    const jwt = await signApnsJwt(env);
    const header = decodeProtectedHeader(jwt);
    expect(header.alg).toBe("ES256");
    expect(header.kid).toBe("KID123");
    const claims = decodeJwt(jwt);
    expect(claims.iss).toBe("TEAM456");
    expect(typeof claims.iat).toBe("number");
  });
});

describe("sendPush (stub seam)", () => {
  it("is a no-op returning { stub: true } when APNS_KEY is absent", async () => {
    const env = stubEnv(); // no APNS_KEY
    const res = await sendPush(env, "devicetokenhex", PAYLOAD);
    expect(res).toEqual({ stub: true });
  });
});
