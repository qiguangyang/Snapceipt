#!/usr/bin/env node
/**
 * Set the App Store age-rating declaration for Snapceipt via the ASC REST API.
 * Truthful content answers for a receipt/expense app are all "none" (computes to 4+);
 * AGE_OVERRIDE (default SIXTEEN_PLUS) manually raises the minimum age band.
 *   AGE_OVERRIDE=NONE node scripts/asc-age-rating.mjs   # keep the honest 4+
 *   node scripts/asc-age-rating.mjs                      # 16+ override (default)
 * Self-loads fastlane/.env so it runs without sourcing.
 */
import { readFileSync } from "node:fs";
import { SignJWT, importPKCS8 } from "jose";

// --- load fastlane/.env -----------------------------------------------------
for (const line of readFileSync(new URL("../fastlane/.env", import.meta.url), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
  if (m) process.env[m[1]] ??= m[2].replace(/^["']|["']$/g, "");
}

const API = "https://api.appstoreconnect.apple.com";
const APP = process.env.APP_ID || "6778894594";
const OVERRIDE = process.env.AGE_OVERRIDE || "SIXTEEN_PLUS";

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

TOKEN = await token();
const ai = await call("GET", `/v1/apps/${APP}/appInfos?limit=1`);
const declId = (await call("GET", `/v1/appInfos/${ai.json.data?.[0]?.id}/ageRatingDeclaration`)).json.data?.id;
if (!declId) { console.error("no ageRatingDeclaration"); process.exit(1); }

// All content "none"/false (truthful for a receipt scanner); override raises the band.
const attributes = {
  alcoholTobaccoOrDrugUseOrReferences: "NONE",
  contests: "NONE",
  gamblingSimulated: "NONE",
  gunsOrOtherWeapons: "NONE",
  horrorOrFearThemes: "NONE",
  matureOrSuggestiveThemes: "NONE",
  medicalOrTreatmentInformation: "NONE",
  profanityOrCrudeHumor: "NONE",
  sexualContentGraphicAndNudity: "NONE",
  sexualContentOrNudity: "NONE",
  violenceCartoonOrFantasy: "NONE",
  violenceRealistic: "NONE",
  violenceRealisticProlongedGraphicOrSadistic: "NONE",
  gambling: false,
  unrestrictedWebAccess: false,
  // 2025 questionnaire additions — all "no objectionable content" for a receipt app.
  advertising: false,
  healthOrWellnessTopics: false,
  messagingAndChat: false,
  parentalControls: false,
  ageAssurance: false,
  lootBox: false,
  userGeneratedContent: false,
  ageRatingOverrideV2: OVERRIDE,
};

const r = await call("PATCH", `/v1/ageRatingDeclarations/${declId}`, {
  data: { type: "ageRatingDeclarations", id: declId, attributes },
});
console.log(`PATCH ageRatingDeclaration -> ${r.status}`);
if (!r.ok) { console.log(JSON.stringify(r.json.errors || r.json, null, 1)); process.exit(1); }
const after = await call("GET", `/v1/ageRatingDeclarations/${declId}`);
console.log("override now:", after.json.data?.attributes?.ageRatingOverrideV2);
console.log("OK");
