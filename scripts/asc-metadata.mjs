#!/usr/bin/env node
/**
 * Upload Snapceipt's App Store listing metadata from fastlane/metadata/* to ASC via the
 * REST API (deliver chokes on the first-version review attachment — fastlane #20538).
 * Idempotent PATCHes; no binary, no screenshots, NO submission. Self-loads fastlane/.env.
 *   node scripts/asc-metadata.mjs
 */
import { readFileSync, existsSync } from "node:fs";
import { SignJWT, importPKCS8 } from "jose";

const ROOT = new URL("..", import.meta.url);
for (const line of readFileSync(new URL("fastlane/.env", ROOT), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
  if (m) process.env[m[1]] ??= m[2].replace(/^["']|["']$/g, "");
}
const md = (p) => {
  const f = new URL(`fastlane/metadata/${p}`, ROOT);
  if (!existsSync(f)) return null;
  const v = readFileSync(f, "utf8").split("\n").filter((l) => !l.trim().startsWith("#")).join("\n").trim();
  return v || null;
};

const API = "https://api.appstoreconnect.apple.com";
const APP = process.env.APP_ID || "6778894594";
const LOCALE = "en-AU";

async function token() {
  const key = await importPKCS8(readFileSync(process.env.ASC_KEY_PATH, "utf8"), "ES256");
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ iss: process.env.ASC_ISSUER_ID, iat: now, exp: now + 900, aud: "appstoreconnect-v1" })
    .setProtectedHeader({ alg: "ES256", kid: process.env.ASC_KEY_ID, typ: "JWT" }).sign(key);
}
let TOKEN;
async function call(method, path, body) {
  const r = await fetch(`${API}${path}`, {
    method, headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const t = await r.text(); let j; try { j = t ? JSON.parse(t) : {}; } catch { j = {}; }
  return { status: r.status, ok: r.ok, json: j };
}
const drop = (o) => Object.fromEntries(Object.entries(o).filter(([, v]) => v != null));
async function patch(label, path, type, id, attributes) {
  const a = drop(attributes);
  if (!Object.keys(a).length) { console.log(`${label}: nothing to set`); return; }
  const r = await call("PATCH", path, { data: { type, id, attributes: a } });
  console.log(`${label}: PATCH -> ${r.status}${r.ok ? " OK (" + Object.keys(a).join(", ") + ")" : " " + JSON.stringify(r.json.errors || r.json)}`);
}

TOKEN = await token();

// --- ids -------------------------------------------------------------------
const appInfoId = (await call("GET", `/v1/apps/${APP}/appInfos?limit=1`)).json.data?.[0]?.id;
const ail = (await call("GET", `/v1/appInfos/${appInfoId}/appInfoLocalizations?limit=20`)).json.data || [];
const aiLoc = ail.find((l) => l.attributes?.locale === LOCALE);
const versions = (await call("GET", `/v1/apps/${APP}/appStoreVersions?limit=10`)).json.data || [];
const ver = versions.find((v) => /PREPARE_FOR_SUBMISSION|DEVELOPER_REJECTED|REJECTED/.test(v.attributes?.appStoreState)) || versions[0];
const vl = (await call("GET", `/v1/appStoreVersions/${ver.id}/appStoreVersionLocalizations?limit=20`)).json.data || [];
const vLoc = vl.find((l) => l.attributes?.locale === LOCALE);
console.log(`appInfo=${appInfoId} aiLoc=${aiLoc?.id} version=${ver.id}(${ver.attributes?.versionString}) vLoc=${vLoc?.id}`);

// --- app-info localization: name, subtitle (<=30), privacy URL -------------
const subtitle = md(`${LOCALE}/subtitle.txt`);
if (subtitle && subtitle.length > 30) console.log(`WARN: subtitle is ${subtitle.length} chars (max 30) — skipping; shorten fastlane/metadata/${LOCALE}/subtitle.txt`);
await patch("appInfoLoc", `/v1/appInfoLocalizations/${aiLoc.id}`, "appInfoLocalizations", aiLoc.id, {
  name: md(`${LOCALE}/name.txt`), subtitle: (subtitle && subtitle.length <= 30) ? subtitle : null, privacyPolicyUrl: md(`${LOCALE}/privacy_url.txt`),
});

// --- version localization: description, keywords, support/marketing URLs ----
await patch("versionLoc", `/v1/appStoreVersionLocalizations/${vLoc.id}`, "appStoreVersionLocalizations", vLoc.id, {
  description: md(`${LOCALE}/description.txt`), keywords: md(`${LOCALE}/keywords.txt`),
  supportUrl: md(`${LOCALE}/support_url.txt`), marketingUrl: md(`${LOCALE}/marketing_url.txt`),
  promotionalText: md(`${LOCALE}/promotional_text.txt`),
});

// --- version: copyright -----------------------------------------------------
await patch("version", `/v1/appStoreVersions/${ver.id}`, "appStoreVersions", ver.id, { copyright: md("copyright.txt") });

// --- categories -------------------------------------------------------------
const pc = md("primary_category.txt"), sc = md("secondary_category.txt");
if (pc) {
  const rel = { primaryCategory: { data: { type: "appCategories", id: pc } } };
  if (sc) rel.secondaryCategory = { data: { type: "appCategories", id: sc } };
  const r = await call("PATCH", `/v1/appInfos/${appInfoId}`, { data: { type: "appInfos", id: appInfoId, relationships: rel } });
  console.log(`categories (${pc}${sc ? "/" + sc : ""}): PATCH -> ${r.status}${r.ok ? " OK" : " " + JSON.stringify(r.json.errors || r.json)}`);
}

// --- App Review contact details --------------------------------------------
const rd = (await call("GET", `/v1/appStoreVersions/${ver.id}/appStoreReviewDetail`)).json.data;
let phone = md("review_information/phone_number.txt");
if (phone && /^\+?0*$/.test(phone.replace(/[\s()-]/g, "").replace(/^\+?\d{1,3}/, ""))) {
  console.log("WARN: review phone is a placeholder (all zeros) — skipping; add a real number before submission");
  phone = null;
}
const reviewAttrs = drop({
  contactFirstName: md("review_information/first_name.txt"), contactLastName: md("review_information/last_name.txt"),
  contactPhone: phone, contactEmail: md("review_information/email_address.txt"),
  notes: md("review_information/notes.txt"), demoAccountRequired: false,
});
if (rd) {
  await patch("reviewDetail", `/v1/appStoreReviewDetails/${rd.id}`, "appStoreReviewDetails", rd.id, reviewAttrs);
} else if (!phone) {
  console.log("reviewDetail: SKIPPED — contactPhone is required and the repo phone is a placeholder. Add the App Review contact (with a real phone) in ASC, or set a real phone in fastlane/metadata/review_information/phone_number.txt and re-run.");
} else {
  const r = await call("POST", `/v1/appStoreReviewDetails`, {
    data: { type: "appStoreReviewDetails", attributes: reviewAttrs, relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: ver.id } } } },
  });
  console.log(`reviewDetail: POST -> ${r.status}${r.ok ? " OK" : " " + JSON.stringify(r.json.errors || r.json)}`);
}

console.log("done.");
