import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, rm, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "./build.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const contentDir = path.join(__dirname, "content/guides");
const outDir = path.join(__dirname, ".test-out/guides");

test("renders each markdown file to an html file with required SEO head", async () => {
  await rm(path.join(__dirname, ".test-out"), { recursive: true, force: true });
  await mkdir(outDir, { recursive: true });
  const { pages } = await build({ contentDir, outDir });
  assert.ok(pages.length >= 1, "expected at least one page");

  for (const page of pages) {
    const html = await readFile(path.join(outDir, `${page.slug}.html`), "utf8");
    assert.match(html, /<title>[^<]+<\/title>/, `${page.slug}: has title`);
    assert.match(html, /<meta name="description" content="[^"]+">/, `${page.slug}: has description`);
    assert.match(html, new RegExp(`<link rel="canonical" href="https://snapceipt.cc/guides/${page.slug}">`), `${page.slug}: canonical`);
    assert.match(html, /<meta property="og:type" content="article">/, `${page.slug}: og:type`);
  }
});
