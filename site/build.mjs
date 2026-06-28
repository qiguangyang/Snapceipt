import { readFile, readdir, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import matter from "gray-matter";
import { marked } from "marked";
import renderPage, { renderIndex, CTA_HTML } from "./template.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const TOP_LEVEL = ["/", "/pricing", "/privacy", "/terms", "/support", "/guides"];

export async function build({ contentDir, outDir, publicDir }) {
  const mdFiles = (await readdir(contentDir)).filter((f) => f.endsWith(".md")).sort();
  const pages = [];
  for (const file of mdFiles) {
    const raw = await readFile(path.join(contentDir, file), "utf8");
    const { data, content } = matter(raw);
    pages.push({
      title: data.title,
      description: data.description,
      slug: data.slug,
      role: data.role,
      keywords: data.keywords || [],
      related: data.related || [],
      updated: data.updated,
      faq: data.faq || null,
      bodyHtml: marked.parse(content) + CTA_HTML,
    });
  }

  // Integrity: unique slugs, resolvable related links.
  const slugs = new Set();
  for (const p of pages) {
    if (slugs.has(p.slug)) throw new Error(`duplicate slug: ${p.slug}`);
    slugs.add(p.slug);
  }
  for (const p of pages) {
    for (const r of p.related) {
      if (!slugs.has(r)) throw new Error(`unresolved related slug "${r}" in "${p.slug}"`);
    }
  }

  await mkdir(outDir, { recursive: true });
  for (const page of pages) {
    await writeFile(path.join(outDir, `${page.slug}.html`), renderPage(page), "utf8");
  }
  await writeFile(path.join(outDir, "index.html"), renderIndex(pages), "utf8");

  // Sitemap: top-level pages + every guide.
  if (publicDir) {
    const guideUrls = pages.map((p) => `https://snapceipt.cc/guides/${p.slug}`);
    const allUrls = [...TOP_LEVEL.map((u) => `https://snapceipt.cc${u === "/" ? "/" : u}`), ...guideUrls];
    const body = allUrls.map((u) => `  <url><loc>${u}</loc></url>`).join("\n");
    const xml = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${body}\n</urlset>\n`;
    await writeFile(path.join(publicDir, "sitemap.xml"), xml, "utf8");
  }

  return { pages };
}

// CLI entry
if (import.meta.url === `file://${process.argv[1]}`) {
  const contentDir = path.join(__dirname, "content/guides");
  const publicDir = path.join(__dirname, "public");
  const outDir = path.join(publicDir, "guides");
  const { pages } = await build({ contentDir, outDir, publicDir });
  console.log(`Built ${pages.length} guide(s) + index + sitemap.`);
}
