import { describe, expect, it } from "vitest";
import { decodeCbor, b64uToBytes, bytesToB64u, bytesToHex } from "../src/lib/cbor";

describe("decodeCbor", () => {
  it("decodes a small map with byte/text/int values", () => {
    // {"fmt":"a","c":1,"b":h'0102'}  (CBOR)
    // a3            map(3)
    //   63 66 6d 74 text(3)="fmt"
    //   61 61       text(1)="a"
    //   61 63       text(1)="c"
    //   01          uint=1
    //   61 62       text(1)="b"
    //   42 01 02    bytes(2)=0x0102
    // (Brief's original literal "a3636662746161616301616249420102" was corrupted:
    //  'm' 0x6d -> 0x62 gave key "fbt", and a spurious 0x49 byte string header;
    //  it neither decodes to the documented object nor is valid CBOR. Corrected here.)
    const hex = "a363666d7461616163016162420102";
    const bytes = Uint8Array.from(hex.match(/../g)!.map((h) => parseInt(h, 16)));
    const obj = decodeCbor(bytes) as Record<string, unknown>;
    expect(obj.fmt).toBe("a");
    expect(obj.c).toBe(1);
    expect(obj.b).toEqual(new Uint8Array([1, 2]));
  });
  it("round-trips base64url", () => {
    const b = new Uint8Array([0, 255, 16, 32]);
    expect(b64uToBytes(bytesToB64u(b))).toEqual(b);
  });

  it("b64uToBytes is encoding-agnostic: standard base64 and base64url decode to the SAME bytes", () => {
    // Apple's DCAppAttestService.generateKey() returns the keyId as STANDARD base64 (padded,
    // may contain +/); the iOS client sends it verbatim in X-Attest-Key-Id. verifyAttestation
    // now compares keyIds by DECODED BYTES, so b64uToBytes MUST accept both encodings. Prove it
    // for a fixed 32-byte array whose two encodings genuinely differ.
    const bytes = new Uint8Array(32).fill(0xfb); // 0xfb×3 → "+/v7" (standard) / "-_v7" (base64url)
    let bin = "";
    for (const x of bytes) bin += String.fromCharCode(x);
    const standard = btoa(bin); // padded standard base64 (contains + and /)
    const url = bytesToB64u(bytes); // base64url, unpadded (- and _, no =)
    // The two encodings really are different strings — otherwise the test would be vacuous.
    expect(standard).not.toBe(url);
    expect(standard).toContain("+");
    expect(standard).toContain("/");
    expect(standard.endsWith("=")).toBe(true); // padded
    // BOTH forms decode back to the identical original bytes.
    expect(b64uToBytes(standard)).toEqual(bytes);
    expect(b64uToBytes(url)).toEqual(bytes);
  });

  // --- extra hardening cases (App Attest depends on these) ---

  it("decodes a 2-byte length uint header (info 25)", () => {
    // 0x19 = maj 0 (uint), info 25 -> read 2 bytes; 0x01 0x00 = (1<<8)|0 = 256
    const bytes = new Uint8Array([0x19, 0x01, 0x00]);
    expect(decodeCbor(bytes)).toBe(256);
  });

  it("decodes a nested map inside a map (attStmt shape)", () => {
    // {"a": {"b": h'ff'}}
    // a1        map(1)
    //   61 61   text(1)="a"
    //   a1      map(1)
    //     61 62 text(1)="b"
    //     41 ff bytes(1)=0xff
    const hex = "a16161a1616241ff";
    const bytes = Uint8Array.from(hex.match(/../g)!.map((h) => parseInt(h, 16)));
    const obj = decodeCbor(bytes) as { a: { b: Uint8Array } };
    expect(obj.a.b).toEqual(new Uint8Array([255]));
  });

  it("bytesToHex encodes low bytes with padding", () => {
    expect(bytesToHex(new Uint8Array([0, 1, 255]))).toBe("0001ff");
  });

  // --- adversarial input (untrusted App Attest blobs) ---

  it("does not pollute Object.prototype via a __proto__ map key", () => {
    // {"__proto__": {"x": 1}}
    // a1                     map(1)
    //   69 5f5f70726f746f5f5f text(9)="__proto__"
    //   a1                   map(1)
    //     61 78              text(1)="x"
    //     01                 uint=1
    const hex = "a1695f5f70726f746f5f5fa1617801";
    const bytes = Uint8Array.from(hex.match(/../g)!.map((h) => parseInt(h, 16)));
    const decoded = decodeCbor(bytes) as Record<string, unknown>;

    // Global prototype must not have been polluted.
    expect(({} as any).x).toBe(undefined);
    // The decoded map is a null-prototype object with "__proto__" as an OWN key.
    expect(Object.getPrototypeOf(decoded)).toBe(null);
    expect(Object.prototype.hasOwnProperty.call(decoded, "__proto__")).toBe(true);
    expect(Object.keys(decoded)).toContain("__proto__");
    expect(decoded["__proto__"]).toEqual(Object.assign(Object.create(null), { x: 1 }));
  });

  it("throws on a truncated byte-string (declared length exceeds input)", () => {
    // 0x42 = maj 2 (bytes), info 2 -> read 2 bytes, but only 1 follows.
    expect(() => decodeCbor(new Uint8Array([0x42, 0x01]))).toThrow();
  });
});
