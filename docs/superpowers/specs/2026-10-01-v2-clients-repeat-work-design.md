# Snapceipt v2 Client Management and Repeat Work Design

**Date:** 2026-10-01 (Australia/Sydney)
**Status:** Product direction agreed; engineering defaults proposed for implementation.
**Baseline:** `e22d995`, repository release configuration `1.1.0`.

## Purpose and agreed scope

V2 helps a broad mix of sole traders manage clients and prepare repeat work. Its core journey is **open client → review previous work → prepare a new quote or invoice → set a follow-up**.

The user selected more complete business tools, then client management, a broad sole-trader audience, and manual repeat work with reminders. The first release contains a Clients hub, contact details and notes, quote/invoice history, outstanding balances, reusable services/items, fresh drafts from previous documents, and client follow-ups. Linking older documents requires user confirmation.

Scheduling recurring document creation, automatic customer messages, booking calendars, payment gateways, job costing, accountant collaboration, new platforms, and pricing changes are outside this release. Existing quotes, invoices, receipts, tax reports, and personal profiles continue to work.

## Proposed engineering defaults

These choices make the plan executable; they were not individually selected in the conversation:

- Keep the existing bottom navigation. Add a Clients card on Business Home. Manage saved services/items from the Clients hub and either document editor.
- Reuse local-first SwiftData and the existing D1 push/pull protocol. Add two syncable entities: `catalogItem` and `clientFollowUp`.
- Schedule follow-up notifications locally on each explicitly enabled device. In-app due lists work without notification permission. No new Worker cron or external provider is needed.
- Keep integer line quantities for this release, matching current tax/document calculations. Units are labels such as `hour`, `visit`, or `item`; fractional quantities are a separate feature.
- Saved item prices exclude GST. Editors convert them to the document's inclusive price convention when necessary and use existing totals engines.
- Do not introduce new entitlements during implementation. Decide any commercial packaging separately before release.

## Existing implementation and its implications

`Client` already stores name, email, mobile phone, and address, scoped to a profile. `ClientPickerSheet` supports search, inline creation, and deletion. It returns copied contact values rather than a client ID.

Quotes hold name/email/address/mobile snapshots; invoices currently hold name/email snapshots. Neither has a `clientId`. `QuoteListViewModel.duplicate` already clones a quote, but does not carry address/mobile or refresh expiry. Quote conversion creates a draft invoice and establishes quote/invoice links. Invoice balances are derived with `AccountsReceivable`; payment totals must not be reimplemented differently for the new hub.

The backend sync route validates the envelope and selected scalar columns, rather than calling all strict entity schemas. Merely adding a Zod entity schema will not protect new references or domain fields. Apply-time validation is part of the implementation.

The persistent container currently falls back to memory on an opening failure. A real upgrade check must prove the v1 store opens and retains data; an apparently working empty fallback is not an acceptable migration result.

## Screens and interaction

### Clients hub

A searchable, name-sorted list with **All clients** and **Follow-ups** filters, an **Add client** action, and **Saved items** in its toolbar. Search matches name, email, and phone. Due follow-ups are visible first in the follow-up view; completed/deleted follow-ups are excluded. The hub is available only within business profiles.

### Client detail and editor

Contact information, one editable freeform notes field, issued-invoice outstanding balance, quote/invoice history, and follow-ups. Actions are **New quote**, **New invoice**, **Create again**, and **Set reminder**. History sorts newest first and shows existing document/payment states.

New quote/invoice actions create a local draft prefilled with the selected client, then open the existing editor. Editors opened from this hub return to that client's detail after closing or saving. Quote conversion can open its resulting invoice within the same hub presentation.

Client editing never rewrites existing document snapshots. Client deletion is a soft deletion: it removes the client from lists/pickers and cancels its follow-ups, while existing quotes, invoices, payments, and copied contact details remain available through their existing lists. Drafts whose linked client has since been deleted require selection of a live client before repeat work.

### Repeat work

Create again produces the same document kind: quote → quote or invoice → invoice. Copy live line descriptions, units, integer quantities, prices, currency, and document GST flags/rate snapshot. Use the linked client's current contact details. Preserve prices and tax convention visibly for review rather than silently repricing.

Generate fresh UUIDs for the document and every line. Reset number, delivery/issue timestamps, PDF keys, origin quote/invoice links, payment records, and status to draft. Set quote validity to today + 28 days and invoice due date to today + 14 days, using the existing document date convention. Do not create an income transaction until the normal issue flow does so. Show **Review prices and dates before sending.**

A source must belong to the signed-in user and active profile, contain at least one live line, and link to a live client. Otherwise show a specific correction action instead of silently producing an incomplete document. Prevent double-tap creation; saving the new parent and lines must succeed before navigation or sync enqueue.

### Saved services and items

Store description, an optional unit label, and unit price excluding GST. Search, create, edit, and soft-delete items per business profile. Inserting an item copies its values to a new document line with quantity 1. Editing or deleting a saved item never changes existing document lines.

For GST-inclusive, GST-enabled documents, convert the saved exclusive price with integer half-up rounding: `floor((exclusiveCents * (10000 + rateBp) + 5000) / 10000)`. Otherwise use the exclusive price unchanged. This is unit-price conversion; existing engines remain authoritative for document totals.

Persist `unitLabel` on quote and invoice lines. Surface it alongside the description in editors, hosted documents, and invoice PDFs; escape it with the existing HTML helpers. Null labels preserve v1 output.

### Follow-ups

A follow-up belongs to a client and profile. It has a title, due instant, timezone used when choosing that instant, and optional completion timestamp. Users can edit/reschedule, mark complete, reopen, or delete it. A reminder never sends anything to the client.

Users choose a future date/time in the displayed timezone. Store `dueAt` as epoch milliseconds and `timezone` as an IANA identifier. Display the chosen zone on the editor/detail. When travelling, the saved instant remains unchanged. Reject nonexistent local clock times during DST transitions; explicitly resolve an ambiguous clock time to the first occurrence and show the resulting timezone offset before save.

Permission denial or scheduling failure leaves the saved follow-up visible with **In-app only**. Notification content is generic: **Client follow-up due** / **Open Snapceipt to review your follow-up.** Client names and notes stay out of lock-screen content.

Reconcile notifications after local edits, successful sync application, sign-in/foreground, and notification preference changes. Schedule the earliest 32 future live follow-ups across the current user's business profiles. Remaining ones display **In-app only** until a later reconciliation schedules them. Past-due entries stay in the due list without producing a burst of late notifications. Each device has its own opt-in; more than one enabled device can notify.

Use identifiers `sc.clientFollowUp.<userId>.<followUpId>` and payload `{type: "client_follow_up", userId, profileId, clientId, followUpId}`. Remove both pending and delivered notifications when completed/deleted or when the user signs out/deletes their account. Cancel reminders for missing/deleted clients and profiles.

Notification taps must resolve the authenticated user, live business profile, client, and follow-up before navigation. Queue a cold-launch tap until auth/store/profile restoration completes. Switch to the reminder's profile explicitly; a stale or foreign-user tap opens no client information.

## Data contract

Use the existing sync envelope: UUIDv7 `id`, `userId`, required `profileId` for new entities, `createdAt`, `updatedAt`, nullable `deletedAt`, `rev`, and nullable `lastEditedDeviceId`. Money is integer cents; timestamps are epoch milliseconds. Device scheduling state is local and is not synced.

| Model/table | Additions and defaults |
| --- | --- |
| `Client` / `clients` | `notes: String?` / `notes TEXT NULL` |
| `Quote` / `quotes` | `clientId: String?` / `client_id TEXT NULL` |
| `Invoice` / `invoices` | `clientId: String?` / `client_id TEXT NULL` |
| `QuoteLineItem` / `quote_line_items` | `unitLabel: String?` / `unit_label TEXT NULL` |
| `InvoiceLineItem` / `invoice_line_items` | `unitLabel: String?` / `unit_label TEXT NULL` |
| `CatalogItem` / `catalog_items` | `itemDescription` / `description TEXT NOT NULL`; `unitLabel` / `unit_label TEXT NULL`; `unitPriceCents` / `unit_price_cents INTEGER NOT NULL`; `currency TEXT NOT NULL DEFAULT 'AUD'` |
| `ClientFollowUp` / `client_follow_ups` | `clientId` / `client_id TEXT NOT NULL`; `title TEXT NOT NULL`; `dueAt` / `due_at INTEGER NOT NULL`; `timezone TEXT NOT NULL`; `completedAt` / `completed_at INTEGER NULL` |

New table profile references use the same foreign-key convention as current profile-scoped tables. Client links are logical references checked in sync, avoiding a new FK that prevents legacy documents and tombstones from surviving client deletion. Index document history by `(user_id, profile_id, client_id, deleted_at, created_at)` and follow-ups by `(user_id, profile_id, completed_at, deleted_at, due_at)`.

Trim names/descriptions/titles; reject blank values. Maximums: client name 200 characters, notes 10,000, item description 500, unit label 40, reminder title 200. Saved item price is `0...1_000_000_000` cents. Validate safe nonnegative integer timestamps and an IANA timezone. Blank optional notes/units normalize to null. Preserve existing contact field behavior.

New links must resolve to a live client owned by the same user and profile. An existing document may retain its unchanged link to a soft-deleted client; assigning a new link to that deleted client is rejected. Unlinking is allowed. Client/profile reassignment that would invalidate live document or follow-up links is rejected. New client mutations precede dependent document/follow-up mutations.

Apply additive migrations after current `0018`. Old clients omit new fields; the server preserves stored values when fields are absent. New clients encode explicit null when intentionally unlinking/clearing fields. Old apps ignore unfamiliar entity types on pull. Because an old app can advance its cursor past unfamiliar records, the v2 upgrade must perform a full pull once for the expanded entity registry while preserving the local outbox. Track completion per user; retry failed full pulls without losing local edits. New registry/type/model totals become 20 syncable entities and 22 SwiftData models including the two existing local-only models.

## Linking existing history

Provide **Link existing documents** on client detail. Suggest only unlinked documents in the same user/profile whose normalized nonempty email matches, or whose normalized name matches. Normalize by trimming and case-folding; collapse internal whitespace for names. Do not apply fuzzy matching or make email equivalence assumptions.

Show document number, original name/email, date, amount, and reason for suggestion. The user selects records and confirms the association. Confirmation writes only `clientId` and sync-envelope edit fields; it does not refresh contact snapshots, totals, status, dates, PDFs, payments, or origin links. A separate same-profile unlinked-document picker supports manual association when no suggestion exists.

Recheck scope and link state on confirmation. Records linked by another edit must not be silently reassigned. No automatic backfill and no association based on name/email during normal history queries.

## Verification and success criteria

- A returning client can be opened and a repeat draft prepared without retyping contact details or line items.
- History and balances include only explicitly linked documents in the current user/profile; drafts, void invoices, deleted rows, and unrelated payments do not inflate outstanding balances.
- Original documents and payments remain identical after client/item edits, legacy association, and repeat-work creation.
- Notes, catalog items, links, and follow-ups survive offline edits, restart, and a second-device sync.
- Follow-ups work in-app with notifications denied, and device notifications cancel correctly on completion, deletion, sign-out, and account deletion.
- A real v1 persistent store upgrades with all existing data preserved.
- Backend suites, iOS unit suites, and the new end-to-end client journey pass before release.

Primary product measures to evaluate after launch: time to prepare a repeat draft, use of Create again/saved items, and completed follow-ups. No unapproved analytics provider is added by this plan.

## Implementation rulings reconciled (2026-10-01)

Workspace reads use authenticated user plus active business profile. The all-business
reminder planner and notification navigation first validate a live business profile
owned by that user, then query with the explicit target profile. No unscoped client
or follow-up reads are permitted.

Successful domain mutations and durable outbox staging commit atomically in an
isolated SwiftData context. A checked staging/save failure preserves typed input
and unrelated pending edits, and never reports success. Legacy-link suggestions
accept explicit userId/profileId and confirmation rechecks the entire selection.

Repeat drafts freeze an absent legacy GST snapshot to the existing engine default
(1000 basis points), preserving historical tax interpretation if profile settings
change. Document currencies remain their saved currencies; client balances group
by currency using the existing AccountsReceivable derivation, with no FX conversion.

Hub-owned invoice draft editors expose an optional successful-save callback and
Save Draft action; failure never dismisses. Other callers retain existing defaults.
Delivered and pending local reminders are reconciled. Profile eligibility observes
identity/type/update changes, including same-count changes.

Version 2.0.0 and upload-ready release-note replacement are reserved for actual
release preparation. NEXT_RELEASE contains proposed copy while staged 1.x work is
preserved. Deploy additive server support before distributing the v2 app.
