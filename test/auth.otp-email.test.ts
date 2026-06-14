import { env } from "cloudflare:test";
import { describe, expect, it, vi } from "vitest";
import { sendSignInCode } from "../src/lib/email";

describe("sendSignInCode", () => {
  it("sends via env.EMAIL.send with the code in the body and the magic-link sender", async () => {
    const sent: Array<{ from: { email: string }; to: string; subject: string; text: string }> = [];
    const fakeEnv = {
      ...env,
      EMAIL: {
        send: vi.fn(async (msg: { from: { email: string }; to: string; subject: string; text: string }) => {
          sent.push(msg);
        }),
      },
    } as unknown as typeof env;

    await sendSignInCode(fakeEnv, { to: "code@example.com", code: "012345" });

    expect(sent).toHaveLength(1);
    expect(sent[0]!.to).toBe("code@example.com");
    expect(sent[0]!.from.email).toBe("noreply@snapceipt.cc");
    expect(sent[0]!.text).toContain("012345");
  });
});
