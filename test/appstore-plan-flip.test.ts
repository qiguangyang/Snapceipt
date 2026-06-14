import { describe, expect, it } from "vitest";
import { applyNotification, NOOP, type DecodedNotification } from "../src/lib/appStoreNotifications";

function notif(over: Partial<DecodedNotification>): DecodedNotification {
  return {
    notificationType: "SUBSCRIBED",
    subtype: undefined,
    originalTransactionId: "1000000999",
    productId: "app.snapceipt.pro.monthly",
    expiresDateMs: 9_999_999_999_000,
    signedDateMs: Date.now(),
    ...over,
  };
}

describe("applyNotification (pure plan-flip reducer)", () => {
  // --- ENTITLING types → pro/active ---

  it("SUBSCRIBED -> pro/active with expiry", () => {
    const r = applyNotification(notif({ notificationType: "SUBSCRIBED" }));
    expect(r).not.toBe(NOOP);
    if (r === NOOP) return;
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
    expect(r.subscriptionExpiresAt).toBe(9_999_999_999_000);
  });

  it("DID_RENEW -> pro/active", () => {
    const r = applyNotification(notif({ notificationType: "DID_RENEW" }));
    expect(r).not.toBe(NOOP);
    if (r === NOOP) return;
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
  });

  it("OFFER_REDEEMED (free trial start) -> pro/active", () => {
    const r = applyNotification(notif({ notificationType: "OFFER_REDEEMED" }));
    expect(r).not.toBe(NOOP);
    if (r === NOOP) return;
    expect(r.plan).toBe("pro");
  });

  it("DID_CHANGE_RENEWAL_STATUS stays pro until expiry (no immediate downgrade)", () => {
    const r = applyNotification(notif({ notificationType: "DID_CHANGE_RENEWAL_STATUS" }));
    expect(r).not.toBe(NOOP);
    if (r === NOOP) return;
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
  });

  it("DID_CHANGE_RENEWAL_PREF -> pro/active", () => {
    const r = applyNotification(notif({ notificationType: "DID_CHANGE_RENEWAL_PREF" }));
    expect(r).not.toBe(NOOP);
    if (r === NOOP) return;
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
  });

  // --- REVOKING types → free/revoked ---

  it("REFUND -> free/revoked", () => {
    const r = applyNotification(notif({ notificationType: "REFUND" }));
    expect(r).not.toBe(NOOP);
    if (r === NOOP) return;
    expect(r.plan).toBe("free");
    expect(r.subscriptionStatus).toBe("revoked");
  });

  it("REVOKE (family sharing removed) -> free/revoked", () => {
    const r = applyNotification(notif({ notificationType: "REVOKE" }));
    expect(r).not.toBe(NOOP);
    if (r === NOOP) return;
    expect(r.plan).toBe("free");
    expect(r.subscriptionStatus).toBe("revoked");
  });

  // --- EXPIRING types → free/expired ---

  it("EXPIRED -> free/expired", () => {
    const r = applyNotification(notif({ notificationType: "EXPIRED" }));
    expect(r).not.toBe(NOOP);
    if (r === NOOP) return;
    expect(r.plan).toBe("free");
    expect(r.subscriptionStatus).toBe("expired");
  });

  it("GRACE_PERIOD_EXPIRED -> free/expired", () => {
    const r = applyNotification(notif({ notificationType: "GRACE_PERIOD_EXPIRED" }));
    expect(r).not.toBe(NOOP);
    if (r === NOOP) return;
    expect(r.plan).toBe("free");
  });

  // --- Explicit no-op types → NOOP sentinel (no DB write) ---

  it("CONSUMPTION_REQUEST -> NOOP (no entitlement change)", () => {
    const r = applyNotification(notif({ notificationType: "CONSUMPTION_REQUEST" }));
    expect(r).toBe(NOOP);
  });

  it("REFUND_DECLINED -> NOOP (no entitlement change)", () => {
    const r = applyNotification(notif({ notificationType: "REFUND_DECLINED" }));
    expect(r).toBe(NOOP);
  });

  it("PRICE_INCREASE -> NOOP (no entitlement change)", () => {
    const r = applyNotification(notif({ notificationType: "PRICE_INCREASE" }));
    expect(r).toBe(NOOP);
  });

  it("RENEWAL_EXTENDED -> NOOP (no entitlement change)", () => {
    const r = applyNotification(notif({ notificationType: "RENEWAL_EXTENDED" }));
    expect(r).toBe(NOOP);
  });

  // --- Fail CLOSED: unknown / future types → NOOP (not pro) ---

  it("unknown type -> NOOP (fail closed, does not grant pro)", () => {
    const r = applyNotification(notif({ notificationType: "SOME_FUTURE_TYPE" }));
    expect(r).toBe(NOOP);
  });

  it("empty-string type -> NOOP (fail closed)", () => {
    const r = applyNotification(notif({ notificationType: "" }));
    expect(r).toBe(NOOP);
  });
});
