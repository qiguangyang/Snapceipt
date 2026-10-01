# Snapceipt v2 Client Management and Repeat Work Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Implement sequentially; this plan does not request subagent delegation.

**Goal:** Give sole traders a client workspace with document history, reusable items, safe repeat-work drafts, and manual follow-up reminders.

**Architecture:** Extend the existing SwiftData/D1 local-first system with explicit client links and two syncable entities. Reuse existing document editors and totals/payment engines; schedule opt-in device reminders through an injected UserNotifications adapter. Keep all new business data scoped to the authenticated user and business profile.

**Tech Stack:** Swift 5.10, SwiftUI, SwiftData, UserNotifications, Swift Testing/XCTest, XcodeGen, TypeScript, Hono, Zod, Cloudflare Workers/D1, Vitest.

**Spec:** [V2 client management and repeat work design](../specs/2026-10-01-v2-clients-repeat-work-design.md).

**Baseline:** `e22d995`; `project.yml` declares iOS 17.0 and release version 1.1.0. This document plans work; no feature implementation or release is included in the planning task.

## Global constraints

- Preserve iOS 17.0 support and the existing five bottom-bar entries.
- Use existing dependencies; no new network service, background scheduler, or analytics SDK.
- Workspace queries require authenticated `userId` and active `profileId`. Reminder planning/navigation may use an explicit target profile only after verifying it is a live business profile owned by that user.
- Money is integer cents; line quantities remain positive integers; IDs are UUIDv7.
- Client editing, catalog editing, history association, and duplication never rewrite historical document snapshots.
- Create again always creates an unsent, unissued draft and never copies payments or creates income.
- Require user confirmation before associating any older document with a client.
- Additive migrations only. Preserve fields omitted by old clients and existing pull-only PDF fields.
- Local save failures show errors and do not navigate, enqueue mutations, or report success.
- Follow-ups are in-app records first; local notifications require per-device opt-in and OS permission.
- Use **Review prices and dates before sending.** and **In-app only** exactly where the spec requires them.
- No automatic customer communication or automatic recurring documents.

## Review focus

1. Identical client names/emails in different profiles or accounts must never merge history or permit a foreign reference (Tasks 2, 4, 5).
2. A deleted client or a stale notification tap must not resurrect a client, expose another account, or keep notifications firing (Tasks 4, 8, 9).
3. Paid/part-paid source invoices and sent quotes must produce fresh drafts with reset identity, dates, delivery state, and payments (Task 6).
4. An old app resaving a document without v2 fields must preserve new links/units; a v1 disk-store upgrade must preserve data (Tasks 1–3, 10).
5. DST transitions, denied permissions, scheduler failures, and more than 32 future follow-ups must preserve the record and explain notification availability (Tasks 7, 8).

## Verification commands

Run commands from the repository root. Before implementation, record actual counts and available tools rather than copying historical suite counts.

```bash
git status --short
node --version
npm run typecheck
npm test
xcodegen generate
xcrun simctl list devices available
```

Select an available iPhone simulator UUID from the inventory and use it in every iOS command below. `<SIMULATOR_UUID>` denotes that observed UUID, not a device to create blindly.

```bash
xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' -only-testing:SnapceiptTests
```

Expected baseline: zero command failures, or documented pre-existing failures distinguished from new regressions. If dependencies/tools are unavailable, record the limitation; do not call unrun checks passing.

## File responsibilities and execution order

| Area | Responsibility |
| --- | --- |
| `migrations/0019_v2_clients_repeat_work.sql` | Additive D1 columns, new tables, and indexes; renumber if 0019 exists at execution time |
| `src/lib/v2SyncValidation.ts` | New-field scalar validation and client-reference/profile invariants |
| `Snapceipt/Model/Entities/{CatalogItem,ClientFollowUp}.swift` | Persisted syncable records |
| `Snapceipt/Sync/ClientWorkspaceSyncMappers.swift` | Mappers for the two new entities using current mapper protocols |
| `Snapceipt/Features/Clients/ClientStore.swift` | Scoped client CRUD and historical-link writes |
| `Snapceipt/Features/Clients/ClientHistory.swift` | History and balances derived from existing documents/payments |
| `Snapceipt/Features/Clients/LegacyClientLinker.swift` | Deterministic suggestions; no automatic writes |
| `Snapceipt/Features/Clients/RepeatWorkService.swift` | Atomic same-kind document cloning and blank client-prefilled drafts |
| `Snapceipt/Features/Catalog/` | Saved-item storage, price conversion, list/editor/picker UI |
| `Snapceipt/Features/Clients/FollowUps/` | Follow-up persistence, time resolution, notification planning/adapter, editor |
| `Snapceipt/Features/Clients/ClientsHubView.swift` | One NavigationStack owning list/detail, sheets, and document presentation |
| Existing app/router/editor files | Entry point, client identity, catalog selection, reminder lifecycle, and safe navigation |

Task dependencies: **1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10**. Tasks 7–8 implement independent catalog/follow-up behavior on the same shared model foundation, but run sequentially to avoid integration churn.

### Task 1: Add the backend schema and wire registry

**Files:**

- Create: `migrations/0019_v2_clients_repeat_work.sql`
- Modify: `src/lib/syncTables.ts`, `src/schemas/entities.ts`, `src/routes/account.ts`
- Create: `test/schema-v2-clients.test.ts`, `test/schemas-v2-clients.test.ts`
- Modify: `test/schemas.test.ts`, `test/account-delete.test.ts`
- Existing verification: `test/account-purge-coverage.test.ts`

**Interfaces:** Add `catalogItem → catalog_items` and `clientFollowUp → client_follow_ups` metadata with `hasProfileId: true`. Add both to `SYNCABLE_TYPES`, `SPECIALIZED`, and `PROFILE_ID_REQUIRED`; total types becomes 20. Wire names/columns/defaults are exactly the spec data-contract table. Export `catalogItemEntity` and `clientFollowUpEntity` schemas; introduce no required `type` field in real iOS mutation payloads.

- [ ] **Step 1: Write migration/contract tests.** `v2ColumnsAndTables` asserts nullable notes/client/unit columns, both new table envelopes, required profile IDs, and indexes. Insert v1-shaped client/quote/invoice/line rows without new columns and assert new values are null. `newEntitySchemaValidation` tests zero/1,000,000,000-cent prices accepted; negative/fractional/1,000,000,001 rejected; blank descriptions/titles rejected; exact length boundaries from the spec; completion null accepted. `accountDeletionWithV2Data` seeds both new tables and expects complete account purge.
- [ ] **Step 2: Run** `npx vitest run test/schema-v2-clients.test.ts test/schemas-v2-clients.test.ts test/account-delete.test.ts`. Expect missing tables/exports before implementation.
- [ ] **Step 3: Implement the migration and maps.** Use existing schema FK/envelope patterns for new tables; use logical client references as specified. Add new tables to `PURGE_ORDER` before clients/profiles. Add optional `clientId`, `notes`, and `unitLabel` fields to matching maps/schemas. Index document client history and due follow-ups. Extend schema tests to derive expected registry count 20 without changing unrelated behavior.
- [ ] **Step 4: Run** `npx vitest run test/schema-v2-clients.test.ts test/schemas-v2-clients.test.ts test/schemas.test.ts test/account-delete.test.ts test/account-purge-coverage.test.ts` and `npm run typecheck`. Expect all selected checks passing.
- [ ] **Step 5: Commit** only this task's files with `feat: add client workspace sync schema`.

### Task 2: Enforce new sync field and reference invariants

**Files:**

- Create: `src/lib/v2SyncValidation.ts`, `test/sync-v2-clients.test.ts`
- Modify: `src/routes/sync.ts`
- Existing verification: `test/sync-security.test.ts`, `test/sync-push.test.ts`, `test/sync-invoices.test.ts`

**Interfaces:** Export `validateV2Mutation(db: D1Database, userId: string, mutation: Mutation, stored: Record<string, unknown> | null): Promise<"FORBIDDEN" | "VALIDATION_FAILED" | null>`. Call after loading/stale-write resolution and before constructing the upsert. Validate the effective merged row (`stored` plus supplied fields), preserving old fields when omitted. Return per-mutation rejection through the existing recorder, not a batch-wide exception.

- [ ] **Step 1: Write real HTTP push/pull tests** using `test/schema-clients.test.ts` session/profile setup. `noTypeV2RoundTrip` sends iOS-style payloads without `type`, then expects notes, units, links, item prices, and reminder fields in pull. `foreignOrOtherProfileClientRejected` expects `FORBIDDEN` and unchanged data. `unknownOrDeletedNewLinkRejected` expects `VALIDATION_FAILED`; unchanged links on older documents to now-deleted clients remain accepted. `oldPayloadPreservesV2Fields` resaves a v1-shaped document and expects stored client/unit fields retained; explicit null clears optional links. `invalidV2ScalarsRejected` exercises limits, fractional timestamps/prices, invalid UUIDs/timezones, and non-string unit labels. `profileMoveWithLinkedRecordsRejected` tests moving a client/document while live links would be invalidated. `newClientThenDocumentInOneBatch` applies parent first and expects both applied; reverse order rejects only the dependent mutation without corrupting the parent.
- [ ] **Step 2: Run** `npx vitest run test/sync-v2-clients.test.ts`. Expect assertions on invalid mutations to fail against the unguarded route.
- [ ] **Step 3: Implement** the validator using explicit Zod validation for the v2 fields without globally enforcing existing strict entity schemas. Query client ownership/profile/liveness using bound parameters. Require a live same-scope client for new or changed links; retain an unchanged link to a tombstoned client on an existing document. Reject unsafe profile moves of clients with live linked records. Deletes retain the current generic tombstone behavior. Dependent writes must follow their client creation in the outbox; a rejected dependent write is visible as a sync error and can be retried after correction with a fresh mutation ID.
- [ ] **Step 4: Run** `npx vitest run test/sync-v2-clients.test.ts test/sync-security.test.ts test/sync-push.test.ts test/sync-invoices.test.ts` and `npm run typecheck`. Expect all checks passing, including the existing no-`type` regression.
- [ ] **Step 5: Commit** with `feat: validate client workspace sync references`.

### Task 3: Add iOS models and complete push/pull codecs

**Files:**

- Create: `Snapceipt/Model/Entities/CatalogItem.swift`, `Snapceipt/Model/Entities/ClientFollowUp.swift`, `Snapceipt/Sync/ClientWorkspaceSyncMappers.swift`
- Modify: `Snapceipt/Model/Entities/Client.swift`, `Snapceipt/Model/Entities/Quote.swift`, `Snapceipt/Model/Entities/Invoice.swift`, `Snapceipt/Model/Entities/QuoteLineItem.swift`, `Snapceipt/Model/Entities/InvoiceLineItem.swift`, `Snapceipt/Model/EntityType.swift`, `Snapceipt/Model/ModelContainer+Snapceipt.swift`, `Snapceipt/Sync/SyncEntityRegistry.swift`, `Snapceipt/Sync/SyncEngine.swift`
- Create: `SnapceiptTests/ClientWorkspaceSyncTests.swift`
- Modify: `SnapceiptTests/ClientModelTests.swift`, `SnapceiptTests/EntityTypeTests.swift`
- Existing verification: `SnapceiptTests/QuoteSyncTests.swift`, `SnapceiptTests/InvoiceModelTests.swift`

**Interfaces:** New `@Model` classes conform to `Syncable`, with exact spec fields and defaulted additive existing-model properties. New cases are `.catalogItem` and `.clientFollowUp`. Register `CatalogItemSyncMapper` and `ClientFollowUpSyncMapper`; `SyncRowMapper` is internal and can be implemented in the new file. Keep existing private mappers in place. Schema total becomes 22 persisted types.

- [ ] **Step 1: Write** `clientWorkspacePayloadAndPullRoundTrip` using an in-memory container and the engine/MockAPIClient pattern in `QuoteSyncTests`. Assert every new camelCase wire field encodes/applies; null `clientId`, `notes`, `unitLabel`, and `completedAt` clear prior values. `legacyPullDefaults` expects omitted additive fields to remain nil on new legacy-shaped rows. `allV2TypesRegistered` asserts 20 entity cases and handlers for both new types. `localWipeIncludesV2Rows` verifies `LocalStore.wipe` removes the two new models. `registryUpgradeFullPullPreservesOutbox` starts with a v1 cursor and pending quote edit, expects a cursorless pull that discovers older catalog/follow-up rows without overwriting the edit, then expects incremental pulls after successful completion. `failedUpgradePullRetries` expects no completed registry-version marker on failure and a retry from the beginning.
- [ ] **Step 2: Generate the project and run** the iOS unit command with `-only-testing:SnapceiptTests/ClientWorkspaceSyncTests` replacing the broader selector. Expect missing model/types until implementation.
- [ ] **Step 3: Implement** models, envelope extensions, mappers, and schema registration. Make only the shared `str`, `num`, `boolv`, and `applySharedEnvelope` helpers internal where the new mapper file needs them; keep existing mapper implementations private. Never add `pdfR2Key` to document pushes. Include `clientId` in quote/invoice payloads and `unitLabel` in both line-item codecs. New required fields get safe initial values for construction and are validated before local persistence. Use optional stored properties/defaults for old models so their migration is additive. Before a user's first v2 pull, reset `sc.syncCursor` when `sc.syncEntityVersion.<userId>` is not 20; preserve the outbox and its local-write protections. Set that per-user marker to 20 only after the full pull succeeds, so an interrupted upgrade retries safely.
- [ ] **Step 4: Run** the selected new suite plus `QuoteSyncTests`, `ClientModelTests`, `InvoiceModelTests`, and `EntityTypeTests` using repeated `-only-testing:` flags. Expect passing round trips and no server-owned-field regression.
- [ ] **Step 5: Commit** with `feat: add client workspace models and sync codecs`.

### Task 4: Carry client identity through selection and document creation

**Files:**

- Create: `Snapceipt/Features/Clients/ClientStore.swift`, `Snapceipt/Features/Clients/ClientEditView.swift`, `SnapceiptTests/ClientStoreTests.swift`
- Modify: `Snapceipt/Features/Quotes/ClientPickerSheet.swift`, `Snapceipt/Features/Quotes/ClientPickerViewModel.swift`, `Snapceipt/Features/Quotes/QuoteEditorView.swift`, `Snapceipt/Features/Quotes/QuoteEditorViewModel.swift`, `Snapceipt/Features/Invoices/InvoiceEditorView.swift`, `Snapceipt/Features/Invoices/InvoiceEditorViewModel.swift`
- Modify tests: `SnapceiptTests/ClientPickerViewModelTests.swift`, `SnapceiptTests/QuoteEditorViewModelTests.swift`, `SnapceiptTests/InvoiceEditorViewModelTests.swift`, `SnapceiptTests/QuoteConvertTests.swift`

**Interfaces:** Define `ClientDraft { name: String, email: String?, mobilePhone: String?, address: String?, notes: String? }` and `ClientSelection { id: String, name: String, email: String?, mobilePhone: String?, address: String? }`. `ClientStore(context:sync:userId:profileId:)` exposes `list(search: String) throws -> [Client]`, `save(id: String?, draft: ClientDraft) throws -> Client`, and `delete(id: String) throws`. Change picker callback to `(ClientSelection) -> Void`. Editors add `setClient(_ selection: ClientSelection)` and retain their existing snapshot-based overload for legacy tests/flows, setting `clientId = nil` on that overload.

- [ ] **Step 1: Write** `clientEditPreservesHistoricalSnapshots`: rename/email-edit a client linked to sent quote/issued invoice; their snapshot strings remain exactly unchanged. `clientCrudScopesBothUserAndProfile` tests foreign-account and other-profile IDs cannot be edited/deleted or returned by search. `clientDeleteCancelsFollowUpsKeepsDocuments` expects client/follow-up tombstones but untouched documents/payments. `selectionPersistsClientId` expects picker selection to survive editor save/load. `convertPreservesClientLinkAndQuoteSnapshot` expects invoice client ID/name/email to match the source quote even after the saved client is edited. `saveFailureDoesNotEnqueue` uses an injected persistence-failure seam and expects an error and zero sync calls.
- [ ] **Step 2: Run** the five relevant unit suites with the iOS command. Expect new identity/store cases to fail before implementation.
- [ ] **Step 3: Implement** scoped CRUD, field limits, throwing saves, and typed selection. Have the existing picker delegate writes/deletes to `ClientStore` so deletion behavior cannot differ between hub and picker. Retain name/email/address/mobile snapshot behavior on documents; add ID to load/save and quote conversion. Save client/follow-up tombstones together before enqueuing. New-client picker enqueue occurs before the dependent document. ClientEditView exposes contact fields and multiline notes with validation errors and no success-dismissal on save failure.
- [ ] **Step 4: Run** the affected unit suites. Expect old unlinked-document flows to remain valid and the new link/snapshot tests to pass.
- [ ] **Step 5: Commit** with `feat: preserve client identity across quote and invoice flows`.

### Task 5: Derive client history and confirm legacy associations

**Files:**

- Create: `Snapceipt/Features/Clients/ClientHistory.swift`, `Snapceipt/Features/Clients/LegacyClientLinker.swift`, `Snapceipt/Features/Clients/LegacyDocumentLinkView.swift`, `SnapceiptTests/ClientHistoryTests.swift`, `SnapceiptTests/LegacyClientLinkerTests.swift`
- Modify: `Snapceipt/Features/Clients/ClientStore.swift`
- Reuse: `Snapceipt/Features/Invoices/AccountsReceivable.swift`

**Interfaces:** `ClientHistory.load(context: ModelContext, userId: String, profileId: String, clientId: String, today: String) throws -> ClientHistory.Snapshot` returns `documents: [Document]`, `outstandingByCurrency: [String: Int]`, and compatibility-only `outstandingCents: Int`, where `Document` carries kind (`quote`/`invoice`), ID, number, created timestamp, total, saved currency, status, and optional derived invoice payment state. Define `ClientHistory.DocumentReference { kind: DocumentKind, id: String }` and `DocumentKind` with `quote`/`invoice` cases. `LegacyClientLinker.suggestions(client: ClientSelection, userId: String, profileId: String, quotes: [Quote], invoices: [Invoice]) -> [Suggestion]` is pure; `Suggestion` carries kind, document ID, and reason (`email`/`name`). `ClientStore.linkExistingDocuments(clientId: String, documents: [ClientHistory.DocumentReference]) throws` performs the user-confirmed write.

- [ ] **Step 1: Write** `historyUsesIdsNotContactEquality` with matching client names/emails but different IDs/profiles/users; expect only explicit same-scope links. `outstandingUsesLiveIssuedInvoices` seeds issued totals 10,000 and 5,000, live payments 3,000 and 6,000, deleted payment 2,000, draft total 9,000, void total 8,000; expect `outstandingCents == 7_000`. `suggestionsNeverWrite` expects deterministic matches and zero context/sync mutations. `ambiguousSameNameNeedsSelection` keeps two candidates explicit. `linkChangesOnlyIdAndEnvelope` compares all financial/snapshot fields before/after and expects equality. `confirmationRechecksCurrentScopeAndLink` refuses a row already linked elsewhere since suggestion generation; do not partially apply the selected set.
- [ ] **Step 2: Run** `ClientHistoryTests` and `LegacyClientLinkerTests` with the iOS unit command. Expect missing helper/API failures.
- [ ] **Step 3: Implement** ID-based queries, per-invoice `AccountsReceivable.derive`, and `max(total - paid, 0)` only for live issued invoices. Filter payments by invoice and user. Implement normalized exact suggestion matches and an explicit same-profile manual unlinked picker. Confirmation validates the entire selection first, stages durable outbox work with the checked atomic boundary, and commits domain/outbox together. Failure exposes no successful mutation. No automatic backfill or historical snapshot refresh.
- [ ] **Step 4: Run** both suites. Expect deterministic ordering, scoped associations, 7,000-cent balance, and unchanged historical fields.
- [ ] **Step 5: Commit** with `feat: add client history and confirmed document association`.

### Task 6: Build safe blank and repeat-work drafts

**Files:**

- Create: `Snapceipt/Features/Clients/RepeatWorkService.swift`, `SnapceiptTests/RepeatWorkServiceTests.swift`
- Modify: `Snapceipt/Features/Quotes/QuoteListViewModel.swift`, `Snapceipt/Features/Quotes/QuoteEditorViewModel.swift`
- Existing tests: `SnapceiptTests/QuoteListViewModelTests.swift`, `SnapceiptTests/QuoteConvertTests.swift`

**Interfaces:** `@MainActor RepeatWorkService(context: ModelContext, sync: any SyncEnqueuing, userId: String, profileId: String)` exposes `newQuote(clientId: String, now: Date) throws -> String`, `newInvoice(clientId: String, now: Date) throws -> String`, `repeatQuote(sourceId: String, now: Date) throws -> String`, and `repeatInvoice(sourceId: String, now: Date) throws -> String`. Return persisted draft IDs. Add internal injected save/clock seams for deterministic failure/date tests. New blank drafts snapshot current profile tax settings; repeat drafts preserve source tax settings and prices.

- [ ] **Step 1: Write** `repeatsPaidInvoiceAsUnpaidDraft` using a paid issued invoice with number/PDF/quote link: expect new ID, new live line IDs, draft status, nil number/PDF/quoteId/issueDate/issuedAt, no payments, due date +14 days, and no new income transaction. `repeatsQuoteWithFreshValidity` expects validity +28 days, nil number/sentAt/PDF/invoiceId, current client contact values, preserved prices/tax flags/units. `repeatDoesNotModifySource` compares source/line/payment snapshots before/after. `emptyOrForeignOrDeletedSourceRejected` covers all correction cases. `doubleTapCreatesOneDraft` belongs to the invoking view-model/action guard and asserts one persisted parent. `failedSaveLeavesNoPartialCloneOrEnqueue` expects rollback and zero sync calls. `blankDraftHasSelectedClientAndCurrentTaxSettings` verifies both document kinds.
- [ ] **Step 2: Run** `RepeatWorkServiceTests` and `QuoteListViewModelTests`. Expect missing service/fresh-date behavior to fail.
- [ ] **Step 3: Implement** scoped parent/client/line fetches, fresh IDs, snapshot copying, state resets, and atomic persistence. Preserve the current UTC document date convention; use injected `now` with explicit calendar timezone. Parent mutation must enqueue before its line mutations. Use a dedicated mutation context or equivalent rollback-safe transaction so a failed clone cannot leave partial records or undo unrelated editor changes. Guard the UI action during creation. Existing linked quote duplication calls the service; existing unlinked v1 duplication keeps its compatibility behavior while copying missing address/mobile and refreshing validity. Quote conversion also carries line units.
- [ ] **Step 4: Run** `RepeatWorkServiceTests`, `QuoteListViewModelTests`, and `QuoteConvertTests`. Expect all state-reset and historical-preservation assertions passing.
- [ ] **Step 5: Commit** with `feat: create safe repeat-work quote and invoice drafts`.

### Task 7: Implement saved items and document unit rendering

**Files:**

- Create: `Snapceipt/Features/Catalog/CatalogStore.swift`, `Snapceipt/Features/Catalog/CatalogPrice.swift`, `Snapceipt/Features/Catalog/CatalogListView.swift`, `Snapceipt/Features/Catalog/CatalogEditorView.swift`, `Snapceipt/Features/Catalog/CatalogPickerSheet.swift`, `SnapceiptTests/CatalogStoreTests.swift`, `SnapceiptTests/CatalogPriceTests.swift`
- Modify: `Snapceipt/Features/Quotes/QuoteEditorView.swift`, `Snapceipt/Features/Quotes/QuoteEditorViewModel.swift`, `Snapceipt/Features/Invoices/InvoiceEditorView.swift`, `Snapceipt/Features/Invoices/InvoiceEditorViewModel.swift`
- Modify: `src/routes/quotes.ts`, `src/routes/invoices.ts`, `src/lib/quoteHtml.ts`, `src/lib/invoiceHtml.ts`, `src/lib/pdfInvoice.ts`
- Modify tests: `test/quoteHtml.test.ts`, `test/invoiceHtml.test.ts`, `test/pdfInvoice.test.ts`, `test/quotes-send.test.ts`, `test/invoices-send-pdf.test.ts`

**Interfaces:** `CatalogStore(context:sync:userId:profileId:)` exposes `list(search: String) throws -> [CatalogItem]`, `save(id: String?, description: String, unitLabel: String?, unitPriceCents: Int) throws -> CatalogItem`, `delete(id: String) throws`. `CatalogPrice.enteredCents(exclusiveCents: Int, gstEnabled: Bool, gstInclusive: Bool, rateBp: Int) throws -> Int` uses the spec's integer half-up formula and checked arithmetic. Editors expose `addCatalogItem(_ item: CatalogItem) throws -> String` returning the new line ID; set quantity 1 and copy values, never link the line's editable values back to the catalog.

- [ ] **Step 1: Write** `catalogIsScopedAndSnapshotsInsertedLines` and assert catalog edits/deletes do not change previously inserted lines. `inclusivePriceConversion` pins `10000 → 11000` at 1000 bp and `5 → 6` at 1000 bp; GST-disabled or exclusive entry keeps 10000 unchanged. `invalidPricesAndOverflowRejected` covers range and checked arithmetic. HTML tests render `hour` and escape `<script>` in unit text; nil units retain the v1 string output. Invoice PDF test confirms unit text is present in its render input/output. Route tests prove units are selected/passed for hosted quote/invoice output and PDF issue/regeneration.
- [ ] **Step 2: Run** `CatalogStoreTests`, `CatalogPriceTests`, and `npx vitest run test/quoteHtml.test.ts test/invoiceHtml.test.ts test/pdfInvoice.test.ts`. Expect new conversion/unit assertions to fail.
- [ ] **Step 3: Implement** CRUD/search by description, limit checks, throwing saves, exclusive-price copy, and editor pickers labelled **Saved items**. Add an optional unit field to manual lines too. Reuse existing totals engines. Include `unit_label` in all relevant line SELECTs and render mappings; quote PDFs use the hosted HTML renderer, so no nonexistent `pdfQuote.ts` is added. Render units next to the description, with existing escaping and bounded PDF wrapping/truncation. Invoice PDF text sanitization must support the same allowed text safely; do not introduce unescaped markup or new fonts by accident.
- [ ] **Step 4: Run** the new iOS suites, both editor suites, the five affected backend suites, and `npm run typecheck`. Expect correct rounding, safe output, and no legacy-render regression.
- [ ] **Step 5: Commit** with `feat: add reusable services and item prices`.

### Task 8: Persist follow-ups and reconcile device notifications

**Files:**

- Create: `Snapceipt/Features/Clients/FollowUps/ClientFollowUpStore.swift`, `Snapceipt/Features/Clients/FollowUps/FollowUpTime.swift`, `Snapceipt/Features/Clients/FollowUps/FollowUpNotificationPlan.swift`, `Snapceipt/Features/Clients/FollowUps/FollowUpNotificationScheduler.swift`, `Snapceipt/Features/Clients/FollowUps/ClientFollowUpEditorView.swift`
- Create: `SnapceiptTests/ClientFollowUpStoreTests.swift`, `SnapceiptTests/FollowUpTimeTests.swift`, `SnapceiptTests/FollowUpNotificationTests.swift`
- Modify: `Snapceipt/Features/Notifications/NotificationsSettingsView.swift`, `Snapceipt/Features/Notifications/NotificationsSettingsViewModel.swift`, `Snapceipt/App/SnapceiptApp.swift`, `Snapceipt/App/RootView.swift`, `Snapceipt/Sync/SyncEngine.swift`

**Interfaces:** `ClientFollowUpStore(context:sync:userId:profileId:)` exposes `save(id: String?, clientId: String, title: String, dueAt: Int, timezone: String, now: Int) throws -> ClientFollowUp`, `complete(id: String, at: Int) throws`, `reopen(id: String) throws`, `delete(id: String) throws`, and `list(clientId: String?, includeCompleted: Bool) throws -> [ClientFollowUp]`. `FollowUpTime.resolve(components: DateComponents, timezone: String) throws -> Resolution` returns `instant: Date`, `isAmbiguous: Bool`, and `offsetSeconds: Int`; missing times throw.

`FollowUpNotificationPlan.requests(followUps: [ClientFollowUp], liveClientIds: Set<String>, liveBusinessProfileIds: Set<String>, userId: String, now: Int, enabled: Bool, authorized: Bool) -> [Request]` is pure, sorted by dueAt then ID and capped at 32. `Request` carries identifier, dueAt, and typed payload. Inject `FollowUpNotificationCenter` with async methods to read authorization/pending IDs, add requests, and remove pending/delivered IDs. `FollowUpNotificationScheduler.reconcile(...) async -> Result` reports scheduled IDs and failures to the UI; `cancelAll(userId: String) async` removes this user's follow-up notifications only.

- [ ] **Step 1: Write** store tests for trim/length/future date validation, complete/reopen/reschedule/delete, same-scope live client requirement, and save failures. Time tests use `Australia/Sydney`: 2026-10-04 02:30 is rejected as nonexistent; 2027-04-04 02:30 resolves to the first occurrence with an ambiguity flag/visible offset. Notification tests inject a fake center: denied/disabled → zero requests but unchanged records; >32 → earliest 32; past-due/completed/deleted/foreign/missing-client records excluded; repeat reconciliation replaces stable IDs without duplicates; changed dueAt updates one request; completion/client deletion/account switch removes pending and delivered entries; add failure returns In-app only state. Reopen of a past-due reminder remains due in-app until rescheduled.
- [ ] **Step 2: Run** `ClientFollowUpStoreTests`, `FollowUpTimeTests`, and `FollowUpNotificationTests`. Expect missing implementations.
- [ ] **Step 3: Implement** persistence, strict time resolution, the pure planner, and UserNotifications adapter. Add per-user/per-device local preference `sc.notif.clientFollowUps.<userId>`, default false. Ask OS permission only from the user's enable/set-reminder action, not on every launch. Keep this separate from the existing backend APNs push toggle/quiet-hours settings; this preference controls explicitly timed local reminders. Observe a new generic `.syncDidApplyChanges` signal emitted after successful push conflict/application and pull saves, without removing `.emailInReceiptArrived`. Reconcile serially and coalesce repeated events; bind auth/user identity to each operation so an old task cannot re-add notifications after sign-out. Chain notification cancellation into the existing auth wipe lifecycle, preserving local-data removal even if notification cleanup fails. Display per-record in-app-only/scheduling status from scheduler results and the 32-entry cap.
- [ ] **Step 4: Run** all three new suites plus existing notification-delegate/settings suites. Expect scoped stable scheduling and correct DST behavior; manually inspect the editor's timezone/ambiguity copy on an available simulator.
- [ ] **Step 5: Commit** with `feat: add client follow-ups and device reminders`.

### Task 9: Build the Clients hub and safe reminder navigation

**Files:**

- Create: `Snapceipt/Features/Clients/ClientsHubView.swift`, `Snapceipt/Features/Clients/ClientsListView.swift`, `Snapceipt/Features/Clients/ClientDetailView.swift`, `Snapceipt/Features/Clients/ClientWorkspaceViewModel.swift`, `Snapceipt/Features/Clients/ClientReminderRouteCoordinator.swift`, `SnapceiptTests/ClientWorkspaceViewModelTests.swift`, `SnapceiptTests/ClientReminderRouteTests.swift`
- Modify: `Snapceipt/App/Router.swift`, `Snapceipt/App/RootView.swift`, `Snapceipt/App/SnapceiptApp.swift`, `Snapceipt/Features/Notifications/NotificationDelegate.swift`, `Snapceipt/Shared/AccessibilityID.swift`
- Modify tests: `SnapceiptTests/RouterTests.swift`, `SnapceiptTests/NotificationDelegateTests.swift`

**Interfaces:** Add `Overlay.clients(clientId: String?)` and `Router.openClient(_ id: String?)`. `ClientsHubView` receives context/sync/api/userId/profileId/initialClientId/onClose/scheduler and owns its NavigationStack plus editor presentation enum. `ClientWorkspaceViewModel` composes stores/history/repeat service; it never replicates money calculations. Add `ClientReminderRoute { userId, profileId, clientId, followUpId }` and an injected `ClientReminderRouteCoordinator.receive(_ route: ClientReminderRoute)` / `resumeAfterSessionRestoration()` pair. This coordinator owns one pending cold-launch route and cancels it on account change/sign-out.

- [ ] **Step 1: Write** `hubActionsReturnToSelectedClient`, `repeatActionDoubleTapGuard`, `reloadAfterSync`, and `personalProfileHasNoClientsEntry`. Routing tests cover ready-session same-profile tap, valid other-business-profile switch, signed-out cold launch followed by same-user restore, different-user restore, deleted client/profile/follow-up, completed follow-up, malformed payload, and sign-out before async restore finishes. Expect only valid current-user live rows to open a client; queueing does not expose contact fields. Existing budget/email notification routing must still pass.
- [ ] **Step 2: Run** the new view-model/routing suites plus RouterTests/NotificationDelegateTests. Expect missing route/coordinator behaviors to fail.
- [ ] **Step 3: Implement** the Clients Business Home card with total/due follow-up counts and a clear open action; keep existing quick actions intact. Implement searchable list, All clients/Follow-ups views, detail, notes editing, outstanding balance, history, completed-follow-up disclosure, link-existing UI, Saved items, and document actions. Hub-owned full-screen editor callbacks return to client detail; quote conversion replaces the hub's current document presentation with its invoice editor. Refresh on local mutation/sync/foreground and recreate the workspace when user/profile changes. Include `.clients` in RootView's overlay presentation, ID, dismiss, and animation switches. Route `client_follow_up` notifications through the coordinator before budget fallback; resolve payload IDs against the current scoped store after restoration and switch profile only after validation. Add stable accessibility IDs with prefixes for dynamic client/document/reminder rows.
- [ ] **Step 4: Run** affected unit suites and a build. Inspect empty states, long notes/descriptions, large text, VoiceOver labels, keyboard dismissal, and Back/Close behavior. Expect existing Home actions and personal profile layout to remain usable.
- [ ] **Step 5: Commit** with `feat: add client workspace and follow-up navigation`.

### Task 10: Verify upgrade, end-to-end journeys, and release readiness

**Files:**

- Create: `SnapceiptUITests/ClientsJourneyUITests.swift`, `SnapceiptTests/ClientWorkspaceUpgradeTests.swift`, `docs/testing/v2-client-workspace-checklist.md`
- Modify: `Snapceipt/App/RootView.swift` debug fixture seam, `SnapceiptTests/FixtureBundlingTests.swift` if upgrade fixtures are bundled, `fastlane/NEXT_RELEASE.md`
- Modify when preparing the actual release: `project.yml`, `fastlane/metadata/en-AU/release_notes.txt`

**Interfaces:** Extend current `-uiTestStub` fixtures rather than introducing a production auth bypass. Provide fixed-ID, two-business-profile client/doc/payment/item/follow-up fixtures for UI tests. The upgrade test uses a file-backed v1 store, created from the baseline model schema in an isolated fixture generator or archived from a baseline test build; it opens with the v2 container and verifies data. A v2-created store reopened as v2 proves restart persistence but does not count as an upgrade test.

- [ ] **Step 1: Write** UI journeys: add client with notes → new quote using saved item → save → history → Create again → review/reset dates → set reminder → mark complete. A separate invoice fixture journey repeats a paid invoice and verifies no copied payment/balance/income state. Switch profiles and ensure clients/notes/history/follow-ups disappear appropriately. Link a legacy document only after confirmation, and verify its original contact data remains. Add disk-upgrade assertions for v1 receipt/client/quote/invoice/line/payment IDs and values, with new properties nil and no fallback to an empty memory store.
- [ ] **Step 2: Run** only the new UI/upgrade suites using the iOS command. Expect journey failures until fixtures/wiring are complete; preserve true xcodebuild exit status, never pipe through a filter that masks it.
- [ ] **Step 3: Complete fixture wiring and acceptance checklist.** Cover offline edit/relaunch, second-device sync, notification denial, completion/reschedule/deletion, sign-out/account deletion, stale/cold-launch taps, DST, >32 reminders, long text, and no historical document rewrites. Document local-notification multi-device behavior and server-first rollout. Record device-only checks explicitly instead of substituting fake-center tests. Write proposed What's New copy to NEXT_RELEASE; bump to 2.0.0 and replace release notes only during the actual release-preparation step after verification, preserving any intervening release work.
- [ ] **Step 4: Run the final checks once:** `npm run typecheck`, `npm test`, `npm run test:e2e`, and the full iOS unit/UI suites. Use `xcodebuild test -project Snapceipt.xcodeproj -scheme Snapceipt -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' -only-testing:SnapceiptTests -only-testing:SnapceiptUITests` for hermetic verification. Run the existing live journey harness for the new client flow in staging/local mode after adding it to the harness if needed. Expect all automated checks passing and record actual counts/results; unresolved device checks remain clearly labelled.
- [ ] **Step 5: Commit** with `test: verify v2 client workflows and upgrades`. Prepare a reviewable PR description linking the spec/plan and reporting validation. Deploy additive D1 migration and Worker support before distributing the v2 iOS build; use the existing staging/release workflow. Production deploy, App Store upload, and publication are separate execution actions, not part of writing this plan.

## Definition of done

- [ ] Clients hub, notes, linked history/balances, reusable items, repeat drafts, and follow-ups are available in business profiles.
- [ ] Legacy association is user-confirmed and snapshot-preserving.
- [ ] New records/fields sync without breaking v1 payloads or server-owned PDF metadata.
- [ ] Scope checks, deleted-client behavior, failed saves, payment isolation, notification lifecycle, and time handling pass their owning tests.
- [ ] A real v1 disk store upgrades with original records preserved.
- [ ] Required automated checks pass; remaining physical-device checks are documented with results.
- [ ] Spec, implementation, release notes, and PR description agree on the final scope.

## Plan self-review

All agreed capabilities map to tasks: client workspace/notes (4, 9), history/balances (5, 9), confirmed legacy links (5), manual repeat work (6), saved items/units (7), follow-ups/notifications (8, 9), and migration/release verification (1–3, 10). The five Review Focus conditions have named tests in their owning tasks. Proposed engineering defaults are identified in the spec; no automatic recurring workflow or new customer messaging service has been added.

Implementation can proceed in this chat using `superpowers:executing-plans` when requested. The shared schema/client identity contracts should land before UI work so every new screen uses the same history, cloning, and notification behavior.

## Final interface/release rulings

Stores, repeat work, conversion and document-editor saves use checked atomic staging
in isolated mutation contexts. Legacy nil GST becomes the existing effective engine
default in a repeated draft. Balances in the client UI use outstandingByCurrency;
the aggregate field remains only for compatibility. InvoiceEditorView has optional
onSavedDraft (default nil), a draft-only Save Draft action when supplied, and a
visible repeat-review banner. Successful callbacks alone return to client detail.

Task 10 prepares proposed copy/checklists and a local PR description. It does not
change project version/build or replace upload-ready release_notes.txt; those belong
to the separately requested release preparation. Additive D1/Worker support rolls
out before the v2 client. Physical VoiceOver, OS delivery and second-device checks
must be reported distinctly from simulator/fake-center automation.
