// All timestamps are epoch milliseconds (UTC). serverStamp() is what the sync
// layer writes onto accepted rows (updatedAt): it is STRICTLY monotonic within a
// single isolate so two writes in the same ms still get distinct, ordered stamps,
// neutralizing skewed client clocks per the LWW contract and keeping the keyset
// cursor's (updatedAt, id) ordering unique.

export function nowMs(): number {
  return Date.now();
}

let lastStamp = 0;

export function serverStamp(): number {
  const t = Date.now();
  // Strictly increasing: if the wall clock has not advanced (or went backwards)
  // since the last stamp, bump by 1ms so two calls never return the same value.
  lastStamp = t > lastStamp ? t : lastStamp + 1;
  return lastStamp;
}
