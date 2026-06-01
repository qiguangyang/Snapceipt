import { defineWorkersConfig, readD1Migrations } from "@cloudflare/vitest-pool-workers/config";
import path from "node:path";

// Read the migration SQL files on the Node side, then hand them to the worker
// through a test-only binding the setup file consumes.
const migrations = await readD1Migrations(path.join(__dirname, "migrations"));

export default defineWorkersConfig({
  test: {
    // The HTTP e2e suite (e2e/**) boots a real worker via `unstable_dev`, which
    // CANNOT run inside vitest-pool-workers. It lives in its own Node-env project
    // (vitest.e2e.config.ts / `npm run test:e2e`) and must be excluded here so
    // the workers-pool `npm test` never tries to collect it.
    exclude: ["**/node_modules/**", "**/dist/**", "e2e/**"],
    setupFiles: ["./test/apply-migrations.ts"],
    poolOptions: {
      workers: {
        // Load main, compatibility_date/flags and bindings from wrangler.jsonc
        // so tests use the same config as `wrangler dev`/`deploy`.
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          // Test-only extras layered on top of wrangler.jsonc bindings.
          compatibilityFlags: ["nodejs_compat"],
          bindings: {
            TEST_MIGRATIONS: migrations,
            // Auth tests sign/verify with this HS256 key (real key stays in
            // .dev.vars locally / `wrangler secret` on deploy).
            JWT_SIGNING_KEY: "test-signing-key-0123456789-abcdefghijklmnop",
            APPLE_BUNDLE_ID: "com.snapceipt.app",
          },
          // .dev.vars isn't read in tests; inject the secrets/vars tests need.
          // (real secrets stay in .dev.vars locally / `wrangler secret` on deploy)
          // JWT_SIGNING_KEY/APPLE_BUNDLE_ID are exercised by later auth tests.
          //
          // The `ai` binding in wrangler.jsonc is compiled by wrangler into a
          // wrapped binding backed by an *external* worker that the
          // vitest-pool-workers runtime can't resolve offline
          // (workers-sdk #6796 / #7434: `unstable_getMiniflareWorkerOptions`
          // emits the wrapped `AI` binding without its external worker, so
          // workerd fails to start with
          // "wrapped binding module can't be resolved __WRANGLER_EXTERNAL_AI_WORKER").
          // Override the AI wrapped binding with a local stub worker so the test
          // runtime boots. AI is unused this phase; later AI tests can mock the
          // model calls against this stub.
          wrappedBindings: {
            AI: { scriptName: "ai-mock" },
          },
          workers: [
            {
              name: "ai-mock",
              modules: true,
              script: `export default function () {
                return {
                  async run() {
                    throw new Error("Workers AI is not available in the test runtime");
                  },
                };
              }`,
            },
          ],
        },
      },
    },
  },
});
