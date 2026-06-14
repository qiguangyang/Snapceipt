import { describe, expect, it } from "vitest";
import { applyNotification, type DecodedNotification } from "../src/lib/appStoreNotifications";

function notif(over: Partial<DecodedNotification>): DecodedNotification {
  return {
    notificationType: "SUBSCRIBED",
    subtype: undefined,
    originalTransactionId: "1000000999",
    productId: "app.snapceipt.pro.monthly",
    expiresDateMs: 9_999_999_999_000,
    ...over,
  };
}

describe("applyNotification (pure plan-flip reducer)", () => {
  it("SUBSCRIBED -> pro/active with expiry", () => {
    const r = applyNotification(notif({ notificationType: "SUBSCRIBED" }));
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
    expect(r.subscriptionExpiresAt).toBe(9_999_999_999_000);
  });

  it("DID_RENEW -> pro/active", () => {
    const r = applyNotification(notif({ notificationType: "DID_RENEW" }));
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
  });

  it("OFFER_REDEEMED (free trial start) -> pro/active", () => {
    const r = applyNotification(notif({ notificationType: "OFFER_REDEEMED" }));
    expect(r.plan).toBe("pro");
  });

  it("EXPIRED -> free/expired", () => {
    const r = applyNotification(notif({ notificationType: "EXPIRED" }));
    expect(r.plan).toBe("free");
    expect(r.subscriptionStatus).toBe("expired");
  });

  it("REFUND -> free/revoked", () => {
    const r = applyNotification(notif({ notificationType: "REFUND" }));
    expect(r.plan).toBe("free");
    expect(r.subscriptionStatus).toBe("revoked");
  });

  it("REVOKE (family sharing removed) -> free/revoked", () => {
    const r = applyNotification(notif({ notificationType: "REVOKE" }));
    expect(r.plan).toBe("free");
    expect(r.subscriptionStatus).toBe("revoked");
  });

  it("GRACE_PERIOD_EXPIRED -> free/expired", () => {
    const r = applyNotification(notif({ notificationType: "GRACE_PERIOD_EXPIRED" }));
    expect(r.plan).toBe("free");
  });

  it("DID_CHANGE_RENEWAL_STATUS stays pro until expiry (no immediate downgrade)", () => {
    const r = applyNotification(notif({ notificationType: "DID_CHANGE_RENEWAL_STATUS" }));
    expect(r.plan).toBe("pro");
    expect(r.subscriptionStatus).toBe("active");
  });
});
