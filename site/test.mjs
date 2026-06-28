import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, rm, mkdir, writeFile } from "node:fs/promises";
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

test("regenerates sitemap.xml containing every guide url exactly once", async () => {
  const publicDir = path.join(__dirname, ".test-out");
  await build({ contentDir, outDir, publicDir });
  const sitemap = await readFile(path.join(publicDir, "sitemap.xml"), "utf8");
  const { pages } = await build({ contentDir, outDir, publicDir });
  for (const page of pages) {
    const loc = `https://snapceipt.cc/guides/${page.slug}`;
    const count = sitemap.split(loc).length - 1;
    assert.equal(count, 1, `${page.slug}: appears exactly once in sitemap`);
  }
});

test("writes a /guides index page listing the guides", async () => {
  const publicDir = path.join(__dirname, ".test-out");
  await build({ contentDir, outDir, publicDir });
  const index = await readFile(path.join(outDir, "index.html"), "utf8");
  assert.match(index, /<title>[^<]*Guides[^<]*<\/title>/i, "index has a Guides title");
});

test("emits Article + BreadcrumbList JSON-LD that parses", async () => {
  const { pages } = await build({ contentDir, outDir, publicDir: path.join(__dirname, ".test-out") });
  for (const page of pages) {
    const html = await readFile(path.join(outDir, `${page.slug}.html`), "utf8");
    const blocks = [...html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)].map((m) => JSON.parse(m[1]));
    const types = blocks.map((b) => b["@type"]);
    assert.ok(types.includes("Article"), `${page.slug}: has Article schema`);
    assert.ok(types.includes("BreadcrumbList"), `${page.slug}: has BreadcrumbList schema`);
  }
});

test("throws when a related slug does not resolve", async () => {
  const tmpContent = path.join(__dirname, ".test-content");
  await rm(tmpContent, { recursive: true, force: true });
  await mkdir(tmpContent, { recursive: true });
  await writeFile(path.join(tmpContent, "a.md"),
    `---\ntitle: A\ndescription: d\nslug: a\nrole: spoke\nrelated: [does-not-exist]\nupdated: 2026-06-28\n---\nbody`, "utf8");
  await assert.rejects(
    () => build({ contentDir: tmpContent, outDir: path.join(__dirname, ".test-out2/guides"), publicDir: path.join(__dirname, ".test-out2") }),
    /related slug/i,
  );
  await rm(tmpContent, { recursive: true, force: true });
});
