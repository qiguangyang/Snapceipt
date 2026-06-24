import { defineWorkersConfig, readD1Migrations } from "@cloudflare/vitest-pool-workers/config";
import path from "node:path";
import { makeTestChain } from "./test/helpers/appleChain";

// Read the migration SQL files on the Node side, then hand them to the worker
// through a test-only binding the setup file consumes.
const migrations = await readD1Migrations(path.join(__dirname, "migrations"));

// Generate ONE Apple-JWS test cert chain (root -> intermediate -> leaf) on the
// Node side, where @peculiar/x509 + reflect-metadata load freely. Its root PEM is
// injected as APPLE_TRUST_ANCHOR_PEM (overriding the real AppleRootCA-G3 in tests)
// and the full chain (incl. the leaf private key) is exposed via TEST_APPLE_CHAIN
// so test helpers can sign verifiable payloads. NONE of this exists in production
// — wrangler.jsonc declares neither binding.
const appleChain = await makeTestChain();

export default defineWorkersConfig({
  test: {
    // The HTTP e2e suite (e2e/**) boots a real worker via `unstable_dev`, which
    // CANNOT run inside vitest-pool-workers. It lives in its own Node-env project
    // (vitest.e2e.config.ts / `npm run test:e2e`) and must be excluded here so
    // the workers-pool `npm test` never tries to collect it.
    exclude: ["**/node_modules/**", "**/dist/**", "e2e/**"],
    setupFiles: ["./test/apply-migrations.ts"],
    // Run suites serially against a single warmed workerd runtime. The
    // vitest-pool-workers runtime lazy-fetches its own npm modules (loupe,
    // devalue, core-js-pure, ...) over a loopback "fallback service" socket the
    // first time each suite touches them. Booting many runtimes in parallel
    // makes those cold-start fetches race and intermittently fail ("No such
    // module .../loupe/...", connect(): Connection refused / EADDRNOTAVAIL),
    // which can escalate to MiniflareCoreError ERR_RUNTIME_FAILURE ("no tests").
    // A single reused worker with no file parallelism warms the module graph
    // once and runs deterministically green. Test isolation is unaffected
    // (isolatedStorage stays on by default, so each test still gets fresh D1/KV).
    fileParallelism: false,
    poolOptions: {
      workers: {
        // One reused runtime instead of one-per-suite (see fileParallelism note).
        singleWorker: true,
        // Use wrangler.test.jsonc instead of wrangler.jsonc.  The test config is
        // identical to the production config except the `ai` binding is omitted.
        // wrangler v4 (used by @cloudflare/vitest-pool-workers 0.8.71) generates
        // an external worker named __WRANGLER_EXTERNAL_AI_WORKER:snapceipt-api
        // whose inline script imports `cloudflare-internal:ai-api` — a module
        // absent from the workerd 1.20250906.0 binary bundled with the pool.
        // That causes workerd to fail at startup.  Omitting the `ai` binding from
        // the test config prevents the external worker from being generated.
        // AI paths are all gated behind E2E_EMAIL_MODE and are not exercised in
        // these unit tests; the production wrangler.jsonc is unchanged.
        wrangler: { configPath: "./wrangler.test.jsonc" },
        miniflare: {
          // Test-only extras layered on top of wrangler.test.jsonc bindings.
          compatibilityFlags: ["nodejs_compat"],
          bindings: {
            TEST_MIGRATIONS: migrations,
            // Auth tests sign/verify with this HS256 key (real key stays in
            // .dev.vars locally / `wrangler secret` on deploy).
            JWT_SIGNING_KEY: "test-signing-key-0123456789-abcdefghijklmnop",
            APPLE_BUNDLE_ID: "com.snapceipt.app",
            // Apple JWS test seam: pin the verifier to the test chain's root and
            // expose the chain so helpers can sign verifiable StoreKit/notification
            // payloads. Production keeps the embedded AppleRootCA-G3 (neither binding
            // is declared in wrangler.jsonc).
            APPLE_TRUST_ANCHOR_PEM: appleChain.rootCertPem,
            TEST_APPLE_CHAIN: JSON.stringify(appleChain),
            // Force the extraction stub path in tests, hermetically: the workers pool DOES
            // load .dev.vars, so a real DEEPSEEK_API_KEY/GEMINI_API_KEY there would otherwise
            // leak in and break the "no key -> stub" tests. Empty overrides keep tests stub-only
            // regardless of local .dev.vars. Real keys stay in .dev.vars / `wrangler secret`.
            DEEPSEEK_API_KEY: "",
            GEMINI_API_KEY: "",
          },
          // .dev.vars isn't read in tests; inject the secrets/vars tests need.
          // (real secrets stay in .dev.vars locally / `wrangler secret` on deploy)
          // JWT_SIGNING_KEY/APPLE_BUNDLE_ID are exercised by later auth tests.
        },
      },
    },
  },
});
