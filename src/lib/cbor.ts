// Minimal CBOR decoder — only the subset Apple App Attest uses: uint (maj 0), negint (maj 1),
// byte string (maj 2), text string (maj 3), array (maj 4), map (maj 5). Indefinite lengths and
// tags/floats are not needed and throw. Enough to parse attestation/assertion objects.

export function b64uToBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
export function bytesToB64u(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
export function bytesToHex(b: Uint8Array): string {
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

class Reader {
  constructor(public buf: Uint8Array, public pos = 0) {}
  u8(): number { return this.buf[this.pos++]!; }
  bytes(n: number): Uint8Array { const s = this.buf.subarray(this.pos, this.pos + n); this.pos += n; return s; }
  uint(info: number): number {
    if (info < 24) return info;
    if (info === 24) return this.u8();
    if (info === 25) { const b = this.bytes(2); return (b[0]! << 8) | b[1]!; }
    if (info === 26) { const b = this.bytes(4); return ((b[0]! << 24) | (b[1]! << 16) | (b[2]! << 8) | b[3]!) >>> 0; }
    if (info === 27) { // 64-bit; App Attest counters fit in <=53 bits
      const b = this.bytes(8); let v = 0; for (const x of b) v = v * 256 + x; return v;
    }
    throw new Error(`cbor: unsupported length info ${info}`);
  }
}

function decodeItem(r: Reader): unknown {
  const ib = r.u8();
  const major = ib >> 5;
  const info = ib & 0x1f;
  switch (major) {
    case 0: return r.uint(info);
    case 1: return -1 - r.uint(info);
    case 2: return r.bytes(r.uint(info)).slice(); // copy
    case 3: return new TextDecoder().decode(r.bytes(r.uint(info)));
    case 4: { const n = r.uint(info); const a: unknown[] = []; for (let i = 0; i < n; i++) a.push(decodeItem(r)); return a; }
    case 5: {
      const n = r.uint(info); const m: Record<string, unknown> = {};
      for (let i = 0; i < n; i++) { const k = decodeItem(r); m[String(k)] = decodeItem(r); }
      return m;
    }
    default: throw new Error(`cbor: unsupported major type ${major}`);
  }
}

export function decodeCbor(bytes: Uint8Array): unknown {
  return decodeItem(new Reader(bytes));
}
