// RFC 9562 UUIDv7: 48-bit big-endian Unix-ms timestamp, version 7, a 12-bit
// sub-millisecond monotonic counter (rand_a), variant 10xx, and 62 random bits.
// Dependency-free: uses globalThis.crypto (available in workerd) for randomness.
// Monotonic guarantee: within the same millisecond the 12-bit counter increments
// so ids generated in order remain lexicographically sortable; on counter overflow
// or a backwards clock we bump the logical timestamp by 1ms.

let lastMs = 0;
let counter = 0; // 12 bits, 0..0xfff

// Precomputed byte -> 2-char hex lookup (00..ff).
const HEX: string[] = [];
for (let i = 0; i < 256; i++) HEX.push((i + 0x100).toString(16).slice(1));

// Byte -> hex helper. The byte is always 0..255 (masked at call sites), so the
// lookup never misses; the fallback only satisfies noUncheckedIndexedAccess.
function hex(byte: number): string {
  return HEX[byte] ?? "00";
}

export function uuidv7(): string {
  let ms = Date.now();

  if (ms > lastMs) {
    lastMs = ms;
    counter = randomCounter();
  } else {
    // same ms or clock went backwards: keep monotonic ordering
    ms = lastMs;
    counter = (counter + 1) & 0xfff;
    if (counter === 0) {
      // counter overflow within a single ms: advance the logical clock
      lastMs += 1;
      ms = lastMs;
      counter = randomCounter();
    }
  }

  const bytes = new Uint8Array(16);

  // 48-bit timestamp (big-endian). Number is safe: ms < 2^48 until year ~10889.
  bytes[0] = (ms / 0x10000000000) & 0xff;
  bytes[1] = (ms / 0x100000000) & 0xff;
  bytes[2] = (ms / 0x1000000) & 0xff;
  bytes[3] = (ms / 0x10000) & 0xff;
  bytes[4] = (ms / 0x100) & 0xff;
  bytes[5] = ms & 0xff;

  // bytes[6..7]: version (0111) + high 12 bits = counter (rand_a)
  bytes[6] = 0x70 | ((counter >>> 8) & 0x0f);
  bytes[7] = counter & 0xff;

  // bytes[8..15]: variant (10xx) + 62 random bits
  const rand = new Uint8Array(8);
  crypto.getRandomValues(rand);
  bytes[8] = 0x80 | (rand[0]! & 0x3f);
  bytes[9] = rand[1]!;
  bytes[10] = rand[2]!;
  bytes[11] = rand[3]!;
  bytes[12] = rand[4]!;
  bytes[13] = rand[5]!;
  bytes[14] = rand[6]!;
  bytes[15] = rand[7]!;

  return (
    hex(bytes[0]!) + hex(bytes[1]!) + hex(bytes[2]!) + hex(bytes[3]!) +
    "-" + hex(bytes[4]!) + hex(bytes[5]!) +
    "-" + hex(bytes[6]!) + hex(bytes[7]!) +
    "-" + hex(bytes[8]!) + hex(bytes[9]!) +
    "-" + hex(bytes[10]!) + hex(bytes[11]!) + hex(bytes[12]!) +
    hex(bytes[13]!) + hex(bytes[14]!) + hex(bytes[15]!)
  );
}

function randomCounter(): number {
  const r = new Uint8Array(2);
  crypto.getRandomValues(r);
  // seed counter in the low half so we have headroom before overflow within a ms
  return ((r[0]! << 8) | r[1]!) & 0x07ff;
}
