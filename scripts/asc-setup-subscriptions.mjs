#!/usr/bin/env node
/**
 * Create Snapceipt's Pro auto-renewable subscriptions in App Store Connect via the
 * ASC REST API. Idempotent (skips anything that already exists by productId).
 *
 *   Validate + inventory only (NO mutations, default):
 *       node scripts/asc-setup-subscriptions.mjs
 *   Live create (mutates your App Store Connect — product IDs are PERMANENT):
 *       APPLY=1 node scripts/asc-setup-subscriptions.mjs
 *
 * Auth: reads the ASC API key from env (same key fastlane uses). Source it first:
 *   set -a; . ./fastlane/.env; set +a        # provides ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH
 * Requires Node 18+ (global fetch) and the repo's `jose` dependency (node_modules).
 *
 * CONFIG (override via env): BASE_TERRITORY (default AUS), MONTHLY_PRICE (9.99),
 * YEARLY_PRICE (79.00), TRIAL_DURATION (TWO_WEEKS), LOCALE (en-AU).
 * NOTE: prices are matched against ASC price points in BASE_TERRITORY's currency —
 * for AUS that is AUD. Confirm AUD vs USD before APPLY (the dry run prints the
 * matched price point so you can verify the currency + amount).
 */
import { readFileSync } from "node:fs";
import { SignJWT, importPKCS8 } from "jose";

const API = "https://api.appstoreconnect.apple.com";
const APPLY = process.env.APPLY === "1";
const BUNDLE_ID = process.env.BUNDLE_ID || "app.snapceipt.Snapceipt";
const GROUP_REF = process.env.GROUP_REF || "Snapceipt Pro";
const BASE_TERRITORY = process.env.BASE_TERRITORY || "AUS"; // Australia
const LOCALE = process.env.LOCALE || "en-AU";
const TRIAL_DURATION = process.env.TRIAL_DURATION || "TWO_WEEKS"; // 14-day free trial
const PRODUCTS = [
  {
    productId: "app.snapceipt.pro.monthly",
    name: "Snapceipt Pro (Monthly)", // <=30 chars, ASC subscription name
    period: "ONE_MONTH",
    groupLevel: 1,
    price: process.env.MONTHLY_PRICE || "9.99",
    localizedName: "Snapceipt Pro",
    description: "BAS-ready export, quotes, logbooks and email-in.",
  },
  {
    productId: "app.snapceipt.pro.yearly",
    name: "Snapceipt Pro (Yearly)",
    period: "ONE_YEAR",
    groupLevel: 1,
    price: process.env.YEARLY_PRICE || "79.00",
    localizedName: "Snapceipt Pro",
    description: "BAS-ready export, quotes, logbooks and email-in.",
  },
];

const log = (...a) => console.log("==>", ...a);
const warn = (...a) => console.warn("[warn]", ...a);
function die(msg) { console.error("[err]", msg); process.exit(1); }

// --- ASC JWT ---------------------------------------------------------------
async function ascToken() {
  const keyId = process.env.ASC_KEY_ID;
  const issuerId = process.env.ASC_ISSUER_ID;
  const keyPath = process.env.ASC_KEY_PATH;
  if (!keyId || !issuerId || !keyPath) {
    die("ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH must be set (source fastlane/.env).");
  }
  let pem;
  try { pem = readFileSync(keyPath, "utf8"); } catch { die(`cannot read .p8 at ASC_KEY_PATH=${keyPath}`); }
  const key = await importPKCS8(pem, "ES256");
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ iss: issuerId, iat: now, exp: now + 1000, aud: "appstoreconnect-v1" })
    .setProtectedHeader({ alg: "ES256", kid: keyId, typ: "JWT" })
    .sign(key);
}

let TOKEN;
async function api(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json; try { json = text ? JSON.parse(text) : {}; } catch { json = { raw: text }; }
  if (!res.ok) {
    const errs = (json.errors || []).map((e) => `${e.status} ${e.code}: ${e.title} — ${e.detail}`).join("\n   ");
    throw new Error(`${method} ${path} -> ${res.status}\n   ${errs || text}`);
  }
  return json;
}

// --- helpers ---------------------------------------------------------------
async function getApp() {
  const r = await api("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(BUNDLE_ID)}&limit=1`);
  const app = r.data?.[0];
  if (!app) die(`no app found for bundleId ${BUNDLE_ID} on this ASC account`);
  return app;
}

async function getOrCreateGroup(appId) {
  const groups = await api("GET", `/v1/apps/${appId}/subscriptionGroups?limit=200`);
  const existing = groups.data?.find((g) => g.attributes?.referenceName === GROUP_REF);
  if (existing) { log(`subscription group "${GROUP_REF}" exists (${existing.id})`); return existing.id; }
  if (!APPLY) { log(`WOULD create subscription group "${GROUP_REF}"`); return null; }
  const created = await api("POST", "/v1/subscriptionGroups", {
    data: { type: "subscriptionGroups", attributes: { referenceName: GROUP_REF }, relationships: { app: { data: { type: "apps", id: appId } } } },
  });
  log(`created subscription group "${GROUP_REF}" (${created.data.id})`);
  return created.data.id;
}

async function listSubs(groupId) {
  if (!groupId) return [];
  const r = await api("GET", `/v1/subscriptionGroups/${groupId}/subscriptions?limit=200`);
  return r.data || [];
}

async function getOrCreateSub(groupId, p, existingSubs) {
  const found = existingSubs.find((s) => s.attributes?.productId === p.productId);
  if (found) { log(`subscription ${p.productId} exists (${found.id}, state=${found.attributes?.state})`); return found.id; }
  if (!APPLY) { log(`WOULD create subscription ${p.productId} (${p.name}, ${p.period})`); return null; }
  const created = await api("POST", "/v1/subscriptions", {
    data: {
      type: "subscriptions",
      attributes: { name: p.name, productId: p.productId, subscriptionPeriod: p.period, familySharable: false, groupLevel: p.groupLevel },
      relationships: { group: { data: { type: "subscriptionGroups", id: groupId } } },
    },
  });
  log(`created subscription ${p.productId} (${created.data.id})`);
  return created.data.id;
}

async function setPrice(subId, p) {
  if (!subId) { log(`WOULD set ${p.productId} price to ${p.price} (${BASE_TERRITORY} currency)`); return; }
  // Eligible price points are per-subscription + per-territory.
  let url = `/v1/subscriptions/${subId}/pricePoints?filter[territory]=${BASE_TERRITORY}&include=territory&limit=200`;
  let match;
  for (let page = 0; page < 30 && url && !match; page++) {
    const r = await api("GET", url);
    match = (r.data || []).find((pp) => pp.attributes?.customerPrice === p.price);
    url = r.links?.next ? r.links.next.replace(API, "") : null;
  }
  if (!match) { warn(`no ${BASE_TERRITORY} price point == ${p.price} for ${p.productId} — set the price manually in ASC`); return; }
  log(`matched price point for ${p.productId}: ${p.price} (${match.id})`);
  // Idempotency: skip if a current price already references this point.
  const cur = await api("GET", `/v1/subscriptions/${subId}/prices?include=subscriptionPricePoint&limit=200`);
  if ((cur.data || []).length) { log(`  price already set for ${p.productId} — leaving as-is`); return; }
  try {
    await api("POST", "/v1/subscriptionPrices", {
      data: {
        type: "subscriptionPrices",
        attributes: { startDate: null },
        relationships: {
          subscription: { data: { type: "subscriptions", id: subId } },
          subscriptionPricePoint: { data: { type: "subscriptionPricePoints", id: match.id } },
        },
      },
    });
    log(`  set base price ${p.price} (${BASE_TERRITORY}); ASC equalises other territories`);
  } catch (e) {
    warn(`could not set price for ${p.productId} via API (${e.message.split("\n")[0]}).`);
    warn(`  -> set it manually in ASC: ${p.price} ${BASE_TERRITORY} (price point ${match.id}).`);
  }
}

async function setTrial(subId, p) {
  if (!subId) { log(`WOULD add a ${TRIAL_DURATION} FREE_TRIAL intro offer to ${p.productId}`); return; }
  const cur = await api("GET", `/v1/subscriptions/${subId}/introductoryOffers?limit=200`);
  if ((cur.data || []).length) { log(`  intro offer already exists for ${p.productId} — leaving as-is`); return; }
  try {
    await api("POST", "/v1/subscriptionIntroductoryOffers", {
      data: {
        type: "subscriptionIntroductoryOffers",
        attributes: { duration: TRIAL_DURATION, offerMode: "FREE_TRIAL", numberOfPeriods: 1 },
        relationships: {
          subscription: { data: { type: "subscriptions", id: subId } },
          territory: { data: { type: "territories", id: BASE_TERRITORY } },
        },
      },
    });
    log(`  added ${TRIAL_DURATION} free-trial intro offer to ${p.productId} (${BASE_TERRITORY})`);
  } catch (e) {
    warn(`could not add trial for ${p.productId} via API (${e.message.split("\n")[0]}).`);
    warn(`  -> add it in ASC: Introductory Offer > Free Trial > ${TRIAL_DURATION} > all countries.`);
  }
}

async function setLocalization(subId, p) {
  if (!subId) { log(`WOULD add ${LOCALE} localization "${p.localizedName}" to ${p.productId}`); return; }
  const cur = await api("GET", `/v1/subscriptions/${subId}/subscriptionLocalizations?limit=200`);
  if ((cur.data || []).some((l) => l.attributes?.locale === LOCALE)) { log(`  ${LOCALE} localization exists for ${p.productId}`); return; }
  await api("POST", "/v1/subscriptionLocalizations", {
    data: {
      type: "subscriptionLocalizations",
      attributes: { locale: LOCALE, name: p.localizedName, description: p.description },
      relationships: { subscription: { data: { type: "subscriptions", id: subId } } },
    },
  });
  log(`  added ${LOCALE} localization to ${p.productId}`);
}

// --- main ------------------------------------------------------------------
(async () => {
  log(APPLY ? "APPLY=1 — LIVE: will create/modify ASC subscriptions" : "DRY RUN (no mutations) — set APPLY=1 to create");
  TOKEN = await ascToken();
  const app = await getApp();
  log(`app: ${app.attributes?.name} (${BUNDLE_ID}, id ${app.id})`);

  const groupId = await getOrCreateGroup(app.id);
  const existingSubs = await listSubs(groupId);
  if (existingSubs.length) log(`existing subscriptions in group: ${existingSubs.map((s) => s.attributes?.productId).join(", ")}`);

  for (const p of PRODUCTS) {
    log(`--- ${p.productId} ---`);
    const subId = await getOrCreateSub(groupId, p, existingSubs);
    await setPrice(subId, p);
    await setTrial(subId, p);
    await setLocalization(subId, p);
  }

  console.log("");
  log("Done.");
  if (!APPLY) {
    log("Re-run with APPLY=1 to create the products. Manual steps the API can't finish:");
    console.log("   - Each subscription needs a review screenshot + review note before submission.");
    console.log("   - Set 'Cleared for Sale' / availability, then submit the group for review (or attach to the next app version).");
    console.log("   - Confirm the matched price points are in the intended currency (AUD vs USD).");
  }
})().catch((e) => die(e.message));
