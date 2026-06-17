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
// Territories the subscriptions are sold in. ASC REJECTS price + intro-offer writes
// ("You need to set up availabilities first") until availability is set, so this MUST
// run before setPrice/setTrial. Default AUS+NZL (the launch markets).
const TERRITORIES = (process.env.TERRITORIES || "AUS,NZL").split(",").map((s) => s.trim()).filter(Boolean);
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

// A subscription GROUP needs a localized display name (shown in the iOS
// Manage-Subscriptions UI). Without it, EVERY subscription in the group stays
// in MISSING_METADATA — even with price/availability/screenshot all set.
async function setGroupLocalization(groupId) {
  if (!groupId) { log(`WOULD set group localization (${LOCALE} "${GROUP_REF}")`); return; }
  const cur = await api("GET", `/v1/subscriptionGroups/${groupId}/subscriptionGroupLocalizations?limit=50`);
  if ((cur.data || []).some((l) => l.attributes?.locale === LOCALE)) { log(`group localization ${LOCALE} exists`); return; }
  await api("POST", "/v1/subscriptionGroupLocalizations", {
    data: {
      type: "subscriptionGroupLocalizations",
      attributes: { name: GROUP_REF, locale: LOCALE },
      relationships: { subscriptionGroup: { data: { type: "subscriptionGroups", id: groupId } } },
    },
  });
  log(`set group localization ${LOCALE} "${GROUP_REF}"`);
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

async function setAvailability(subId, p) {
  if (!subId) { log(`WOULD set ${p.productId} availability to ${TERRITORIES.join(",")}`); return; }
  let cur; try { cur = await api("GET", `/v1/subscriptions/${subId}/subscriptionAvailability`); } catch { cur = {}; }
  if (cur.data) { log(`  availability already set for ${p.productId} — leaving as-is`); return; }
  await api("POST", "/v1/subscriptionAvailabilities", {
    data: {
      type: "subscriptionAvailabilities",
      attributes: { availableInNewTerritories: false },
      relationships: {
        subscription: { data: { type: "subscriptions", id: subId } },
        availableTerritories: { data: TERRITORIES.map((id) => ({ type: "territories", id })) },
      },
    },
  });
  log(`  set availability for ${p.productId}: ${TERRITORIES.join(",")}`);
}

async function setPrice(subId, p) {
  if (!subId) { log(`WOULD set ${p.productId} price ${p.price} across ${TERRITORIES.join(",")}`); return; }
  // Find the base-territory price point matching the configured amount. Match by
  // NUMERIC value: the API returns "79.0" where our config says "79.00".
  let baseId;
  let url = `/v1/subscriptions/${subId}/pricePoints?filter[territory]=${BASE_TERRITORY}&limit=200`;
  for (let page = 0; page < 30 && url && !baseId; page++) {
    const r = await api("GET", url);
    const m = (r.data || []).find((pp) => parseFloat(pp.attributes?.customerPrice) === parseFloat(p.price));
    if (m) baseId = m.id;
    url = r.links?.next ? r.links.next.replace(API, "") : null;
  }
  if (!baseId) { warn(`no ${BASE_TERRITORY} price point == ${p.price} for ${p.productId} — set manually`); return; }

  // Which territories already have a price? (per-territory idempotency — the old code
  // skipped if ANY price existed, so non-base territories were never priced.)
  const cur = await api("GET", `/v1/subscriptions/${subId}/prices?include=territory&limit=200`);
  const priced = new Set((cur.included || []).filter((x) => x.type === "territories").map((t) => t.id));

  // Price EVERY availability territory. An available-but-unpriced territory keeps the
  // sub in MISSING_METADATA. Non-base territories use the Apple tier-EQUALIZED point
  // (same tier as the base) — creating one base price does NOT auto-price the rest via API.
  for (const terr of TERRITORIES) {
    if (priced.has(terr)) { log(`  ${terr} price already set for ${p.productId} — leaving as-is`); continue; }
    let pointId = baseId;
    if (terr !== BASE_TERRITORY) {
      const eq = await api("GET", `/v1/subscriptionPricePoints/${baseId}/equalizations?filter[territory]=${terr}&limit=1`);
      pointId = eq.data?.[0]?.id;
      if (!pointId) { warn(`no ${terr} equalization for ${p.productId} — set price manually`); continue; }
    }
    try {
      await api("POST", "/v1/subscriptionPrices", {
        data: {
          type: "subscriptionPrices",
          attributes: { startDate: null },
          relationships: {
            subscription: { data: { type: "subscriptions", id: subId } },
            subscriptionPricePoint: { data: { type: "subscriptionPricePoints", id: pointId } },
          },
        },
      });
      log(`  set ${terr} price for ${p.productId} (point ${pointId})`);
    } catch (e) {
      warn(`could not set ${terr} price for ${p.productId}: ${e.message.split("\n")[0]}`);
    }
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
  await setGroupLocalization(groupId); // group display name — required to clear MISSING_METADATA.
  const existingSubs = await listSubs(groupId);
  if (existingSubs.length) log(`existing subscriptions in group: ${existingSubs.map((s) => s.attributes?.productId).join(", ")}`);

  for (const p of PRODUCTS) {
    log(`--- ${p.productId} ---`);
    const subId = await getOrCreateSub(groupId, p, existingSubs);
    await setAvailability(subId, p); // MUST precede price/trial — ASC 409s otherwise.
    await setPrice(subId, p);
    await setTrial(subId, p);
    await setLocalization(subId, p);
  }

  console.log("");
  log("Done.");
  if (!APPLY) {
    log("Re-run with APPLY=1 to create the products. Manual steps the API can't finish:");
    console.log("   - Each subscription needs a review screenshot + review note (this clears the");
    console.log("     final 'Missing Metadata' and is required before submission).");
    console.log("   - Submit the group for review (or attach to the next app version).");
    console.log("   - Confirm the matched price points are in the intended currency (AUD vs USD).");
    console.log("   - Ensure the Paid Applications Agreement is Active (ASC > Business).");
  }
})().catch((e) => die(e.message));
