# App Store Connect — App Privacy questionnaire answers

Source of truth: `Snapceipt/PrivacyInfo.xcprivacy`. This sheet is for the human
filling the ASC App Privacy section (ASC does not read the manifest). If you
change PrivacyInfo.xcprivacy, update this file in the same PR.

## Tracking
- **Does this app collect data used to track the user?** NO.
  (PrivacyInfo: `NSPrivacyTracking = false`, `NSPrivacyTrackingDomains` empty.)
- No data type below is used for tracking
  (`NSPrivacyCollectedDataTypeTracking = false` on all 8).

## Data collected (8 types)
Every type: **Linked to the user = Yes** (`...Linked = true`),
**Used for tracking = No**, **Purpose = App Functionality**
(`...PurposeAppFunctionality`). Set these three the same for each row.

| ASC category | ASC data type | Linked | Tracking | Purpose |
| --- | --- | --- | --- | --- |
| Contact Info | Email Address | Yes | No | App Functionality |
| Contact Info | Name | Yes | No | App Functionality |
| Identifiers | User ID | Yes | No | App Functionality |
| Identifiers | Device ID | Yes | No | App Functionality |
| Purchases | Purchase History | Yes | No | App Functionality |
| Financial Info | Other Financial Info | Yes | No | App Functionality |
| User Content | Photos or Videos | Yes | No | App Functionality |
| User Content | Other User Content | Yes | No | App Functionality |

## NOT collected (answer "No"/leave unchecked)
- Location (precise or coarse) — none.
- Contacts — none.
- Browsing/Search History — none.
- Health & Fitness — none.
- Sensitive Info — none.
- Diagnostics (Crash/Performance) — none. (No analytics or crash SDK ships;
  re-check before submit — see open_questions. If one is added, add
  "Diagnostics > Crash Data" here AND to PrivacyInfo.xcprivacy.)

## Notes for the reviewer copy (matches privacy policy at snapceipt.cc/privacy)
- Email/Name: account (Sign in with Apple or magic link).
- User ID/Device ID: account scoping + push delivery (push token + device info).
- Purchase History: Apple In-App Purchase subscription state.
- Other Financial Info: receipt/transaction amounts, GST, totals.
- Photos or Videos: receipt photos captured/imported.
- Other User Content: notes, quotes, logbook/budget entries.
- OCR sends only extracted receipt **text** to the processor — never name/email
  (matches privacy.html: "Only receipt text is sent for reading").
