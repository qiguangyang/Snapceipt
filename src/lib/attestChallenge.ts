import { bytesToB64u } from "./cbor";

const TTL_SECONDS = 120;

export async function mintChallenge(kv: KVNamespace): Promise<string> {
  const c = bytesToB64u(crypto.getRandomValues(new Uint8Array(32)));
  await kv.put(`att_chal:${c}`, "1", { expirationTtl: TTL_SECONDS });
  return c;
}

export async function consumeChallenge(kv: KVNamespace, challenge: string): Promise<boolean> {
  const key = `att_chal:${challenge}`;
  const hit = await kv.get(key);
  if (hit === null) return false;
  await kv.delete(key);
  return true;
}
