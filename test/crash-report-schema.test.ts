import { describe, expect, it } from "vitest";
import { crashReportSchema } from "../src/schemas/crashReport";

describe("crashReportSchema", () => {
  it("accepts a MXCrashDiagnostic-shaped payload", () => {
    const r = crashReportSchema.safeParse({
      kind: "crash",
      appVersion: "0.1.0",
      osVersion: "iOS 18.5",
      deviceModel: "iPhone16,2",
      occurredAt: 1_718_400_000_000,
      payload: { exceptionType: 1, signal: 11, terminationReason: "Namespace SIGNAL" },
    });
    expect(r.success).toBe(true);
  });

  it("accepts kind=hang", () => {
    expect(crashReportSchema.safeParse({
      kind: "hang", appVersion: "0.1.0", osVersion: "iOS 18.5",
      deviceModel: "iPhone16,2", occurredAt: 1, payload: { hangDurationMs: 2500 },
    }).success).toBe(true);
  });

  it("rejects an unknown kind", () => {
    expect(crashReportSchema.safeParse({
      kind: "panic", appVersion: "0.1.0", osVersion: "iOS 18.5",
      deviceModel: "iPhone16,2", occurredAt: 1, payload: {},
    }).success).toBe(false);
  });

  it("rejects a missing payload", () => {
    expect(crashReportSchema.safeParse({
      kind: "crash", appVersion: "0.1.0", osVersion: "iOS 18.5",
      deviceModel: "iPhone16,2", occurredAt: 1,
    }).success).toBe(false);
  });

  it("rejects an over-cap payload (>256KB)", () => {
    expect(crashReportSchema.safeParse({
      kind: "crash", appVersion: "0.1.0", osVersion: "iOS 18.5",
      deviceModel: "iPhone16,2", occurredAt: 1,
      payload: { blob: "a".repeat(300_000) },
    }).success).toBe(false);
  });
});
