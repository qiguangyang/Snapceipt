import { readFile, readdir, writeFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import matter from "gray-matter";
import { marked } from "marked";
import renderPage from "./template.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export async function build({ contentDir, outDir }) {
  const mdFiles = (await readdir(contentDir)).filter((f) => f.endsWith(".md"));
  const pages = [];
  for (const file of mdFiles) {
    const raw = await readFile(path.join(contentDir, file), "utf8");
    const { data, content } = matter(raw);
    const bodyHtml = marked.parse(content);
    pages.push({
      title: data.title,
      description: data.description,
      slug: data.slug,
      role: data.role,
      keywords: data.keywords || [],
      related: data.related || [],
      updated: data.updated,
      bodyHtml,
    });
  }

  await mkdir(outDir, { recursive: true });
  for (const page of pages) {
    const html = renderPage(page);
    await writeFile(path.join(outDir, `${page.slug}.html`), html, "utf8");
  }
  return { pages };
}

// CLI entry
if (import.meta.url === `file://${process.argv[1]}`) {
  const contentDir = path.join(__dirname, "content/guides");
  const outDir = path.join(__dirname, "public/guides");
  const { pages } = await build({ contentDir, outDir });
  console.log(`Built ${pages.length} guide(s).`);
}
