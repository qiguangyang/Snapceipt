import { execFileSync } from "node:child_process";
import path from "node:path";

/** Test fixture only: grant the intended entitlement in this suite's isolated LOCAL D1. */
export function grantLocalPro(repoRoot: string, persistDir: string, userId: string): void {
  if (!/^[0-9a-f-]{36}$/i.test(userId)) throw new Error("Invalid fixture user ID");
  execFileSync("node", [path.join(repoRoot, "node_modules/wrangler/bin/wrangler.js"),
    "d1", "execute", "snapceipt", "--local", "--persist-to", persistDir,
    "--command", `UPDATE users SET plan='pro', subscription_status='active', subscription_expires_at=NULL WHERE id='${userId}'`],
  { cwd: repoRoot, stdio: "pipe", env: { ...process.env, CI: "1", WRANGLER_SEND_METRICS: "false" } });
}
