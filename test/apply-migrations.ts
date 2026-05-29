import { applyD1Migrations, env } from "cloudflare:test";

// TEST_MIGRATIONS is a test-only binding populated in vitest.config.ts via
// readD1Migrations(). applyD1Migrations is idempotent (it tracks applied
// migrations in a d1_migrations bookkeeping table), so running it in a global
// setup file once per test worker is safe.
declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    TEST_MIGRATIONS: D1Migration[];
    // Secrets/vars injected by vitest.config.ts (the generated `interface Env`
    // from `wrangler types` omits secrets, which aren't declared in wrangler.jsonc).
    JWT_SIGNING_KEY: string;
    APPLE_BUNDLE_ID: string;
  }
}

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
