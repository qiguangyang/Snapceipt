// Single source of layout truth for generated guide pages.
// Mirrors the nav/footer/fonts of site/public/index.html so guides look native.

const SITE = "https://snapceipt.cc";
const APP_URL = "https://apps.apple.com/au/app/id6778894594";

const FONT_LINKS = `<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400;0,9..144,500;0,9..144,600;1,9..144,500&family=Inter:wght@400;500;600&family=Schibsted+Grotesk:wght@500;600;700;800&family=Hanken+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet">`;

const NAV = `  <nav id="nav" class="nav">
    <a class="logo" href="/">Snap<b>ceipt</b></a>
    <div class="links">
      <a href="/guides">Guides</a>
      <a href="/pricing">Pricing</a>
      <a href="/support">Support</a>
      <a class="navbadge" href="${APP_URL}">Get the app</a>
    </div>
  </nav>`;

const FOOTER = `<footer class="footer"><div class="inner">
  <a class="logo" style="font-size:18px" href="/">Snap<b>ceipt</b></a>
  <a href="/guides">Guides</a><a href="/pricing">Pricing</a><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a>
  <a href="mailto:support@snapceipt.cc">support@snapceipt.cc</a>
  <span class="sp">© 2026 Snapceipt · Made in Australia 🇦🇺</span>
</div></footer>`;

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function jsonLd(page, url) {
  const article = {
    "@context": "https://schema.org", "@type": "Article",
    headline: page.title, description: page.description,
    datePublished: page.updated, dateModified: page.updated,
    author: { "@type": "Organization", name: "Snapceipt" },
    publisher: { "@type": "Organization", name: "Snapceipt", logo: { "@type": "ImageObject", url: `${SITE}/favicon.svg` } },
    mainEntityOfPage: url,
  };
  const crumbs = {
    "@context": "https://schema.org", "@type": "BreadcrumbList",
    itemListElement: [
      { "@type": "ListItem", position: 1, name: "Home", item: SITE },
      { "@type": "ListItem", position: 2, name: "Guides", item: `${SITE}/guides` },
      { "@type": "ListItem", position: 3, name: page.title, item: url },
    ],
  };
  const blocks = [article, crumbs];
  if (page.faq && page.faq.length) {
    blocks.push({
      "@context": "https://schema.org", "@type": "FAQPage",
      mainEntity: page.faq.map((f) => ({ "@type": "Question", name: f.q, acceptedAnswer: { "@type": "Answer", text: f.a } })),
    });
  }
  return blocks.map((b) => `<script type="application/ld+json">${JSON.stringify(b)}</script>`).join("\n");
}

export default function renderPage(page) {
  const url = `${SITE}/guides/${page.slug}`;
  const schema = jsonLd(page, url);
  return `<!doctype html>
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(page.title)}</title>
<meta name="description" content="${esc(page.description)}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="canonical" href="${url}">
<meta property="og:type" content="article">
<meta property="og:title" content="${esc(page.title)}">
<meta property="og:description" content="${esc(page.description)}">
<meta property="og:url" content="${url}">
<meta property="og:image" content="${SITE}/assets/og-default.png">
<meta name="twitter:card" content="summary_large_image">
${FONT_LINKS}
<link rel="stylesheet" href="/site.css">
${schema}
</head>
<body>
<div class="wrap">
${NAV}
  <article class="prose article">
    <nav class="crumbs" aria-label="Breadcrumb"><a href="/">Home</a> › <a href="/guides">Guides</a> › <span>${esc(page.title)}</span></nav>
    <h1>${esc(page.title)}</h1>
    ${page.bodyHtml}
  </article>
</div>
${FOOTER}
</body>
</html>
`;
}

export function renderIndex(pages) {
  const pillar = pages.find((p) => p.role === "pillar");
  const spokes = pages.filter((p) => p.role === "spoke");
  const ordered = pillar ? [pillar, ...spokes] : spokes;
  const items = ordered.map((p) =>
    `      <li><a href="/guides/${p.slug}">${esc(p.title)}</a><p>${esc(p.description)}</p></li>`).join("\n");
  return `<!doctype html>
<html lang="en-AU">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Guides — Snapceipt</title>
<meta name="description" content="Practical guides to tracking receipts, expenses and GST in Australia.">
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="canonical" href="${SITE}/guides">
<meta property="og:type" content="website">
<meta property="og:title" content="Guides — Snapceipt">
<meta property="og:url" content="${SITE}/guides">
<meta property="og:image" content="${SITE}/assets/og-default.png">
${FONT_LINKS}
<link rel="stylesheet" href="/site.css">
</head>
<body>
<div class="wrap">
${NAV}
  <section class="prose article">
    <div class="kicker">Guides</div>
    <h1>Receipt &amp; expense guides</h1>
    <ul class="guideList">
${items}
    </ul>
  </section>
</div>
${FOOTER}
</body>
</html>
`;
}

export const CTA_HTML = `<aside class="ctaBlock">
  <h2>Stop typing receipts.</h2>
  <p>Snapceipt reads the merchant, total, GST and category from a photo — instantly. Made in Australia for sole traders &amp; households.</p>
  <a class="badge" href="${APP_URL}" aria-label="Download Snapceipt on the App Store"><img src="/assets/app-store-badge.svg" alt="Download on the App Store"></a>
</aside>`;

export { SITE, APP_URL, esc };
