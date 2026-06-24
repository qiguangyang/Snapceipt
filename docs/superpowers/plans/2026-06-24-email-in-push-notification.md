# Email-in receipt push notification + auto-refresh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send an APNs push the moment an email-in receipt becomes a transaction, so the app notifies the user and refreshes (foreground → sync; tap → open that receipt's review editor).

**Architecture:** Reuse the existing budget-alert APNs stack. Backend: generalize `ApnsPayload`, add a best-effort `notifyEmailInReceipt` helper, call it from `inboundEmailLogic` on `created`/`failed`. iOS: a `Router` receipt deep-link + an `email_in` branch in `NotificationDelegate` that triggers `SyncEngine.sync()` and opens the review editor.

**Tech Stack:** Cloudflare Workers (Hono, TypeScript), vitest + `@cloudflare/vitest-pool-workers`; iOS SwiftUI + Swift Testing, XcodeGen.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-24-email-in-push-notification-design.md`. Base branch: `feat/email-in-push` (has the spec commit).
- **Visible push only** (no `content-available`/silent). **Fires on `created` AND `failed`**, never on rejections. **Respects `push_enabled`; does NOT respect quiet-hours.**
- **No new env/secret.** APNs is provisioned (`APNS_KEY`/`APNS_KEY_ID`/`APNS_TEAM_ID`); `sendPush` stub-gates when `APNS_KEY` is absent (tests have no `APNS_KEY` → hermetic).
- Alert copy (exact): `created` → title `"New receipt"`, body `"From {merchant} — tap to review."` (empty merchant → `"New emailed receipt — tap to review."`); `failed` → title `"Receipt received"`, body `"Couldn't read it automatically — tap to review."`.
- Custom payload keys (top-level, alongside `aps`): `type: "email_in"`, `transactionId`, `deepLink: "snapceipt://receipt/<id>"`.
- The helper queries: `SELECT apns_token FROM devices WHERE user_id = ? AND deleted_at IS NULL AND push_enabled = 1 AND apns_token IS NOT NULL`. On `sendPush` returning `{stub:false, status: 410|400}`, null that token (mirror `budgetAlert`). The whole helper is best-effort (never throws; a push failure must not affect email ingestion).
- The budget-alert path stays behavior-identical. The in-app camera scan path is untouched.
- Backend tests: `npx vitest run <file>` / `npx vitest run`. iOS: `xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/<Suite>`. Swift concurrency: adjust `@Sendable`/`@MainActor`/actor annotations as needed to compile; the test seams below are sketches of intent.

## File structure

- `src/lib/apns.ts` — generalize `ApnsPayload` (Task 1).
- `src/email/notify.ts` — NEW `notifyEmailInReceipt` helper (Task 1).
- `src/email/inbound.ts` — call the helper on created/failed (Task 2).
- `Snapceipt/App/Router.swift` — `openEmailInReceipt` + receipt deep-link (Task 3).
- `Snapceipt/Features/Notifications/NotificationDelegate.swift` — `email_in` routing + refresh seam (Task 4).
- `Snapceipt/App/SnapceiptApp.swift` — inject the refresh seam (Task 4).

---

### Task 1: `notifyEmailInReceipt` helper + generalize `ApnsPayload` (backend)

**Files:**
- Modify: `src/lib/apns.ts` (generalize `ApnsPayload`)
- Create: `src/email/notify.ts`
- Test: `test/notify.test.ts`

**Interfaces:**
- Produces: `export async function notifyEmailInReceipt(env: Env, userId: string, transactionId: string, merchant: string, extraction: "done" | "failed", nowMs: number): Promise<void>` — best-effort; queries the owner's push-enabled devices and `apns.sendPush`es the email-in payload to each; nulls dead tokens.
- `ApnsPayload` gains optional `type?: string` + `transactionId?: string`; `budgetId`/`deepLink` become optional.

- [ ] **Step 1: Write the failing test** — `test/notify.test.ts`

```ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import { env } from "cloudflare:test";
import * as apns from "../src/lib/apns";
import { notifyEmailInReceipt } from "../src/email/notify";

const T = 1_700_000_000_000;
async function seedUserWithDevice(userId: string, token: string | null, pushEnabled = 1) {
  await env.DB.prepare(`INSERT INTO users (id, plan, created_at, updated_at) VALUES (?, 'pro', ?, ?)`).bind(userId, T, T).run();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, platform, apns_token, push_enabled, created_at, updated_at)
     VALUES (?, ?, 'ios', ?, ?, ?, ?)`,
  ).bind(`dev_${userId}`, userId, token, pushEnabled, T, T).run();
}

describe("notifyEmailInReceipt", () => {
  beforeEach(() => vi.restoreAllMocks());

  it("pushes the created payload to an enabled device", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_created", "tok_created");
    await notifyEmailInReceipt(env, "u_created", "txn1", "Woolworths", "done", T);
    expect(spy).toHaveBeenCalledTimes(1);
    const [, token, payload] = spy.mock.calls[0];
    expect(token).toBe("tok_created");
    expect(payload.aps.alert.title).toBe("New receipt");
    expect(payload.aps.alert.body).toBe("From Woolworths — tap to review.");
    expect(payload.type).toBe("email_in");
    expect(payload.transactionId).toBe("txn1");
    expect(payload.deepLink).toBe("snapceipt://receipt/txn1");
  });

  it("uses the failed copy and the no-merchant fallback", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_failed", "tok_failed");
    await notifyEmailInReceipt(env, "u_failed", "txn2", "", "failed", T);
    const p = spy.mock.calls[0][2];
    expect(p.aps.alert.title).toBe("Receipt received");
    expect(p.aps.alert.body).toBe("Couldn't read it automatically — tap to review.");

    const spy2 = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await env.DB.prepare(`UPDATE devices SET apns_token = 'tok_nomerch' WHERE user_id = 'u_failed'`).run();
    await notifyEmailInReceipt(env, "u_failed", "txn3", "", "done", T);
    expect(spy2.mock.calls.at(-1)![2].aps.alert.body).toBe("New emailed receipt — tap to review.");
  });

  it("skips a push-disabled device and a null-token device", async () => {
    const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
    await seedUserWithDevice("u_off", "tok_off", 0);
    await notifyEmailInReceipt(env, "u_off", "txn4", "X", "done", T);
    await seedUserWithDevice("u_nulltok", null);
    await notifyEmailInReceipt(env, "u_nulltok", "txn5", "X", "done", T);
    expect(spy).not.toHaveBeenCalled();
  });

  it("nulls the token on a 410 and never throws on a sendPush error", async () => {
    vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 410 });
    await seedUserWithDevice("u_410", "tok_410");
    await notifyEmailInReceipt(env, "u_410", "txn6", "X", "done", T);
    const row = await env.DB.prepare(`SELECT apns_token FROM devices WHERE user_id = 'u_410'`).first<{ apns_token: string | null }>();
    expect(row?.apns_token).toBeNull();

    vi.spyOn(apns, "sendPush").mockRejectedValue(new Error("boom"));
    await seedUserWithDevice("u_throw", "tok_throw");
    await expect(notifyEmailInReceipt(env, "u_throw", "txn7", "X", "done", T)).resolves.toBeUndefined();
  });
});
```

(If `users` requires more NOT-NULL columns than `id/plan/created_at/updated_at`, mirror the minimal user INSERT used by `test/inbound.test.ts`/`test/plan.test.ts`.)

- [ ] **Step 2: Run — expect FAIL** (`notifyEmailInReceipt` not found)

Run: `npx vitest run test/notify.test.ts`
Expected: FAIL (import/undefined).

- [ ] **Step 3: Implement**

In `src/lib/apns.ts`, change the interface:
```ts
export interface ApnsPayload {
  aps: { alert: { title: string; body: string }; sound: string };
  deepLink?: string;
  budgetId?: string;
  type?: string;
  transactionId?: string;
}
```
(`budgetAlert.ts` still sets `budgetId`/`deepLink` — it compiles unchanged.)

Create `src/email/notify.ts`:
```ts
import type { Env } from "../env";
import * as apns from "../lib/apns";

/** Best-effort APNs notify for an ingested email-in receipt. Pushes to every push-enabled
 * device of the owner; nulls a token APNs reports dead (410/400). NEVER throws — a push
 * failure must not affect email ingestion. No-op when no eligible device / APNS_KEY absent
 * (sendPush stubs). */
export async function notifyEmailInReceipt(
  env: Env, userId: string, transactionId: string, merchant: string,
  extraction: "done" | "failed", nowMs: number,
): Promise<void> {
  try {
    const created = extraction === "done";
    const body = created
      ? (merchant ? `From ${merchant} — tap to review.` : "New emailed receipt — tap to review.")
      : "Couldn't read it automatically — tap to review.";
    const payload: apns.ApnsPayload = {
      aps: { alert: { title: created ? "New receipt" : "Receipt received", body }, sound: "default" },
      type: "email_in",
      transactionId,
      deepLink: `snapceipt://receipt/${transactionId}`,
    };
    const { results } = await env.DB.prepare(
      `SELECT apns_token FROM devices
        WHERE user_id = ? AND deleted_at IS NULL AND push_enabled = 1 AND apns_token IS NOT NULL`,
    ).bind(userId).all<{ apns_token: string }>();
    for (const d of results) {
      try {
        const r = await apns.sendPush(env, d.apns_token, payload);
        if (r.stub === false && (r.status === 410 || r.status === 400)) {
          await env.DB.prepare(`UPDATE devices SET apns_token = NULL, updated_at = ? WHERE apns_token = ?`)
            .bind(nowMs, d.apns_token).run();
        }
      } catch (err) {
        console.warn(`[email-in:push] sendPush failed for ${String(d.apns_token).slice(0, 8)}…:`, err);
      }
    }
  } catch (err) {
    console.warn("[email-in:push] notify failed:", err);
  }
}
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `npx vitest run test/notify.test.ts` then `npx vitest run`
Expected: PASS; full suite stays green.

- [ ] **Step 5: Commit**

```bash
git add src/lib/apns.ts src/email/notify.ts test/notify.test.ts
git commit -m "feat(email-in/push): notifyEmailInReceipt helper + generalize ApnsPayload"
```

---

### Task 2: Call `notifyEmailInReceipt` from `inboundEmailLogic` (backend)

**Files:**
- Modify: `src/email/inbound.ts`
- Test: `test/inbound.test.ts`

**Interfaces:**
- Consumes: `notifyEmailInReceipt(env, userId, transactionId, merchant, extraction, nowMs)` (Task 1).

- [ ] **Step 1: Write the failing test** — add to `test/inbound.test.ts` (mirror the file's existing Pro-owner + device seeding + Gemini-mock helpers):

```ts
import * as apns from "../src/lib/apns";

it("pushes on a created email-in receipt", async () => {
  const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
  // seed a Pro owner WITH a push_enabled device + apns_token; mock Gemini → created
  const res = await inboundEmailLogic(envProOwnerWithDevice, msgWithImage, NOW);
  expect(res.status).toBe("created");
  expect(spy).toHaveBeenCalledTimes(1);
  expect(spy.mock.calls[0][2].type).toBe("email_in");
});

it("does not push when a free user is bounced", async () => {
  const spy = vi.spyOn(apns, "sendPush").mockResolvedValue({ stub: false, status: 200 });
  const res = await inboundEmailLogic(envFreeOwner, msgWithImage, NOW);
  expect(res).toEqual({ status: "rejected", reason: "pro_only" });
  expect(spy).not.toHaveBeenCalled();
});

it("still creates the txn if the push throws (best-effort)", async () => {
  vi.spyOn(apns, "sendPush").mockRejectedValue(new Error("apns down"));
  const res = await inboundEmailLogic(envProOwnerWithDevice, msgWithImage, NOW);
  expect(res.status).toBe("created");
});
```

- [ ] **Step 2: Run — expect FAIL** (no push on created)

Run: `npx vitest run test/inbound.test.ts`
Expected: FAIL — `sendPush` not called.

- [ ] **Step 3: Implement** — in `src/email/inbound.ts`, import the helper and call it right before the final `return` (after `logInbound`):
```ts
import { notifyEmailInReceipt } from "./notify";
// ...
  await logInbound(
    env.DB, messageId, owner, transactionId,
    extraction === "done" ? "created" : "failed",
    overCap ? "over_cap" : null, now,
  );
  await notifyEmailInReceipt(env, owner.userId, transactionId, receipt.merchant, extraction, now);
  return { status: "created", transactionId, extraction };
```

- [ ] **Step 4: Run tests — expect PASS**

Run: `npx vitest run test/inbound.test.ts` then `npx vitest run`
Expected: PASS; full suite green.

- [ ] **Step 5: Commit**

```bash
git add src/email/inbound.ts test/inbound.test.ts
git commit -m "feat(email-in/push): notify on created/failed inbound receipts"
```

---

### Task 3: iOS `Router` receipt deep-link

**Files:**
- Modify: `Snapceipt/App/Router.swift`
- Test: `SnapceiptTests/RouterTests.swift` (create or extend)

**Interfaces:**
- Produces: `Router.openEmailInReceipt(_ id: String)`, `Router.parseReceiptDeepLink(_:) -> String?`, `Router.handleReceiptDeepLink(_:) -> Bool`.

- [ ] **Step 1: Write the failing test** — `SnapceiptTests/RouterTests.swift`

```swift
import Testing
@testable import Snapceipt

@MainActor struct RouterTests {
    @Test func receiptDeepLinkOpensReview() {
        let r = Router()
        #expect(r.handleReceiptDeepLink(URL(string: "snapceipt://receipt/txn123")!) == true)
        #expect(r.overlay == .emailInReview(id: "txn123"))
    }
    @Test func nonReceiptDeepLinkIgnored() {
        let r = Router()
        #expect(r.handleReceiptDeepLink(URL(string: "snapceipt://budget/b1")!) == false)
        #expect(r.overlay == nil)
    }
    @Test func openEmailInReceiptSetsOverlay() {
        let r = Router()
        r.openEmailInReceipt("abc")
        #expect(r.overlay == .emailInReview(id: "abc"))
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`openEmailInReceipt`/`handleReceiptDeepLink` undefined)

Run: `xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/RouterTests`
Expected: FAIL (compile/undefined).

- [ ] **Step 3: Implement** — in `Snapceipt/App/Router.swift`, alongside `openBudget`/`handleBudgetDeepLink`:
```swift
    /// Open the email-in review editor for transaction `id` (tapped push / receipt deep-link).
    func openEmailInReceipt(_ id: String) { overlay = .emailInReview(id: id) }

    /// Parse `snapceipt://receipt/<id>` -> the transaction id, or nil for any other URL.
    static func parseReceiptDeepLink(_ url: URL) -> String? {
        guard url.scheme == "snapceipt", url.host == "receipt" else { return nil }
        let id = url.pathComponents.first(where: { $0 != "/" })
        guard let id, !id.isEmpty else { return nil }
        return id
    }

    /// If `url` is a receipt deep-link, open its review editor and return true.
    @discardableResult
    func handleReceiptDeepLink(_ url: URL) -> Bool {
        guard let id = Router.parseReceiptDeepLink(url) else { return false }
        openEmailInReceipt(id)
        return true
    }
```

- [ ] **Step 4: Run tests — expect PASS**

Run: same command as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/App/Router.swift SnapceiptTests/RouterTests.swift
git commit -m "feat(ios): Router receipt deep-link -> email-in review editor"
```

---

### Task 4: iOS `NotificationDelegate` email-in routing + refresh seam

**Files:**
- Modify: `Snapceipt/Features/Notifications/NotificationDelegate.swift`
- Modify: `Snapceipt/App/SnapceiptApp.swift`
- Test: `SnapceiptTests/NotificationDelegateTests.swift` (create)

**Interfaces:**
- Consumes: `Router.openEmailInReceipt`, `Router.handleBudgetDeepLink`, `Router.openBudget` (existing), `Router.present(.emailIn)`.
- Produces: `NotificationDelegate.refreshOnPush: (@Sendable () async -> Void)?`, `NotificationDelegate.route(userInfo:router:refresh:) async`.

- [ ] **Step 1: Write the failing test** — `SnapceiptTests/NotificationDelegateTests.swift`

```swift
import Testing
import Foundation
@testable import Snapceipt

actor RefreshSpy { var count = 0; func mark() { count += 1 } }

@MainActor struct NotificationDelegateTests {
    @Test func emailInPushOpensReceiptAndRefreshes() async {
        let router = Router()
        let spy = RefreshSpy()
        await NotificationDelegate.route(
            userInfo: ["type": "email_in", "transactionId": "txn123"],
            router: router, refresh: { await spy.mark() })
        let c = await spy.count
        #expect(c == 1)
        #expect(router.overlay == .emailInReview(id: "txn123"))
    }
    @Test func emailInPushNoTxnFallsBackToList() async {
        let router = Router()
        await NotificationDelegate.route(userInfo: ["type": "email_in"], router: router, refresh: nil)
        #expect(router.overlay == .emailIn)
    }
    @Test func budgetPushStillRoutes() async {
        let router = Router()
        await NotificationDelegate.route(userInfo: ["budgetId": "b1"], router: router, refresh: nil)
        #expect(router.overlay == .budgetEditor(id: "b1"))
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`route`/`refreshOnPush` undefined)

Run: `xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/NotificationDelegateTests`
Expected: FAIL (compile/undefined).

- [ ] **Step 3: Implement**

In `NotificationDelegate.swift`, add the seam + the routing function, and route both handlers through it:
```swift
    /// Set by SnapceiptApp: refresh app data when an email-in push arrives (SyncEngine.sync()).
    static var refreshOnPush: (@Sendable () async -> Void)?

    /// Central push routing (testable). email_in → refresh then open the receipt (fallback list);
    /// otherwise the existing budget deep-link / budgetId routing.
    @MainActor
    static func route(userInfo: [AnyHashable: Any],
                      router: Router?,
                      refresh: (@Sendable () async -> Void)?) async {
        if userInfo["type"] as? String == "email_in" {
            await refresh?()
            if let txn = userInfo["transactionId"] as? String, !txn.isEmpty {
                router?.openEmailInReceipt(txn)
            } else {
                router?.present(.emailIn)
            }
            return
        }
        if let deep = userInfo["deepLink"] as? String, let url = URL(string: deep) {
            router?.handleBudgetDeepLink(url)
        } else if let id = userInfo["budgetId"] as? String {
            router?.openBudget(id)
        }
    }
```
Replace the body of `didReceive` with:
```swift
        await Self.route(userInfo: response.notification.request.content.userInfo,
                         router: Self.router, refresh: Self.refreshOnPush)
```
In `willPresent`, refresh on email-in before returning the presentation options:
```swift
        if notification.request.content.userInfo["type"] as? String == "email_in" {
            await Self.refreshOnPush?()
        }
        return [.banner, .sound]
```

In `SnapceiptApp.swift` `init`, after `NotificationDelegate.api = api` (≈line 96):
```swift
        NotificationDelegate.refreshOnPush = { await sync.sync() }
```
(`sync` is the `SyncEngine` created at ≈line 43.)

- [ ] **Step 4: Run tests — expect PASS** (focused, then the broader suites that touch Router/notifications)

Run: `xcodegen generate && xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SnapceiptTests/NotificationDelegateTests -only-testing:SnapceiptTests/RouterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Snapceipt/Features/Notifications/NotificationDelegate.swift Snapceipt/App/SnapceiptApp.swift SnapceiptTests/NotificationDelegateTests.swift
git commit -m "feat(ios): route email-in push -> sync + open review editor"
```

---

## Post-implementation (controller)

1. Whole-branch review (most-capable model) over `feat/email-in-push`.
2. Full backend `vitest` + full iOS suite green.
3. Merge → deploy worker (no secret change needed). The iOS side ships in the next TestFlight build.

## Self-review

- **Spec coverage:** generalize ApnsPayload (T1) ✓; notify helper w/ device query + dead-token cleanup + best-effort (T1) ✓; fire on created+failed, not rejections (T2) ✓; respect push_enabled / ignore quiet-hours (T1 query) ✓; visible push only (no content-available anywhere) ✓; Router deep-link (T3) ✓; delegate foreground sync + tap → review editor + fallback (T4) ✓; SyncEngine DI (T4) ✓; copy/payload-keys constants ✓; budget path unchanged (ApnsPayload optional fields; budget branch retained in `route`) ✓; no new env/secret ✓.
- **Placeholders:** none — every step carries code/commands.
- **Type consistency:** `notifyEmailInReceipt(env,userId,transactionId,merchant,extraction,nowMs)` defined T1, consumed T2; `route(userInfo:router:refresh:)` + `refreshOnPush` defined T4; `openEmailInReceipt`/`handleReceiptDeepLink` defined T3, consumed T4.
