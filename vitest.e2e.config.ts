import { defineConfig } from "vitest/config";

/**
 * E2E vitest project — runs in the DEFAULT (Node) environment, NOT the
 * vitest-pool-workers pool. This is mandatory: `unstable_dev` boots a real
 * workerd dev server (Miniflare) in a child process and can NOT run inside the
 * workers pool. Kept in its own config + `npm run test:e2e` script so the
 * green workers-pool suite (`npm test`) is untouched.
 *
 * The single e2e spec boots the REAL worker over an HTTP socket and drives the
 * full authenticated flow black-box via `fetch`. Boot + migrate is slow, so the
 * timeouts are generous and the file runs single-threaded.
 */
export default defineConfig({
  test: {
    include: ["e2e/**/*.e2e.test.ts"],
    // Node env — no cloudflare:test, no workers pool.
    environment: "node",
    // Booting workerd + applying migrations is slow; give it room.
    testTimeout: 120_000,
    hookTimeout: 120_000,
    // One worker server at a time (shared dev server across the file).
    fileParallelism: false,
    pool: "forks",
  },
});
