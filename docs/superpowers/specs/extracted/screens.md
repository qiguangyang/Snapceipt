# HomeScreen (Dashboard / Home tab). Sub-components defined in this file: TopBar (profile-switcher header), ProfileSwitcher (segmented / menu / scroll variants — note: HomeScreen actually uses TopBar, not ProfileSwitcher, for the header), ModeToggle (segmented / pills / underline variants), SummaryCard (net-this-month), SnapCTA (feature / gradient / tile variants), QuickAction, TxnRow, BudgetRow. Overlays it routes to live in shell.jsx (AlertsSheet, ProfilePickerSheet, CaptureFlow, etc.) and are summarized in notes.

**Route:** tab === 'home' (default tab, persisted to localStorage 'sc-tab'). Rendered inside IOSDevice frame (402x874) under app-root which injects --accent / --accent-soft / --accent-deep = active profile palette[0/1/2] plus --p/--p-soft/--p-deep and --b/--b-soft/--b-deep. Mounted with key={tab+activeId} so it remounts (and replays entry animation) on tab or profile change.

**Purpose:** Dashboard for the active profile: shows who you are (profile-switcher header + alerts bell), net cash position this month, a prominent AI-snap-receipt CTA, mode-aware quick actions, a budgets/tax-deductible tracker card, and the 4 most recent transactions. It is the primary launch pad into capture, manual entry, loyalty, mileage/WFH logs (Personal) or quotes/reports/receipts (Business).

**Mode-aware:** Mode = active profile's type ('personal' or 'business'); set indirectly by switching profile (setMode(m) picks the first profile of that type). Differences on Home: (1) SummaryCard income/expense/net computed only from txns where t.mode === mode; the capitalized mode badge text changes. (2) Accent re-skins everything at runtime — Personal = terracotta --p #E8602C / soft #FDEBE0 / deep #C2461A; Business = teal --b #0E7C72 / soft #DCF0ED / deep #0A5950. --accent/-soft/-deep are bound to the active palette so SummaryCard gradient, SnapCTA panel, QuickAction icons, links, bell dot all change hue. (3) Quick actions differ: Personal = Loyalty Card / Add Manually / Mileage / WFH log; Business = Create Quote / Add Manually / Reports / Receipts. (4) Tracker card differs: Personal = 'Monthly budgets' (Groceries, Eating out, Utilities) with 'Edit' link, all --accent tinted; Business = 'Deductible · FY26' with green 'Tracked' shield pill and rows Software&subs (#7B5BD6), Vehicle&travel (--accent, over-cap->alert), Meals 50% rule (--income). Note: each ALL_PROFILES profile can carry a custom palette (e.g. Lumen Studio blue #3F5BB0, Rentals green #2F7A55) even when type==='business', so do not hardcode teal for all business profiles — read palette per profile.

## Layout

### Scroll container
Full-height vertical scroll (.scroll: overflow-y auto, no scrollbar). .stagger class applies entry animation to each direct child. Content sits above the floating tab bar.

_Components & tokens:_ div.scroll.stagger; padding 54px (top, clears status bar/notch) 18px (sides) 124px (bottom, clears 64px tab bar + its 22px bottom inset + FAB overhang). Background inherited --cream #FBF6F0. Font --ui Hanken Grotesk, color --ink #211C18.

### 1. TopBar — profile-switcher header
Row: left = tappable profile button (avatar + ACTIVE PROFILE label + name + chevron-down pill if >1 profile); right = bell button with unread dot. Tapping left (when multi) opens profilePicker sheet; bell opens alerts.

_Components & tokens:_ Outer flex space-between, padding 4px 2px 0. Avatar: 46x46, radius 15, linear-gradient(135deg, palette[0]->palette[2]), white initials, font --display 700 / 17px, boxShadow 0 6px 14px -6px palette[0]. Gap 12 to text block. Label 'Active profile': 11.5px, --ink-3 #A99F93, weight 700, uppercase, letter-spacing 0.4. Name: 19px, weight 700, letter-spacing -0.3, line-height 1.15, color --ink. Chevron pill (only if profiles.length>1): 22x22 circle radius 999, bg --paper-2 #F6EEE4, Icon chevD size14 color --ink-2 #6B6258 sw2.2. Bell button: 44x44, radius 14, bg --paper #FFFFFF, 1px border --line #ECE3D8, --sh-card, marginLeft 8; Icon bell size21 color --ink-2; unread dot absolute top11 right12, 8x8 circle, bg --accent, 2px solid --paper border.

### 2. SummaryCard — Net this month
Gradient accent hero card. Header row: 'Net this month · May' label + capitalized mode badge. Big net number. Two inner tiles: Income (arrowDown) and Expenses (arrowUp).

_Components & tokens:_ marginTop 16. Radius --r-card 22, padding 18/18/16, color #fff, background linear-gradient(150deg, --accent 0%, --accent-deep 100%), boxShadow 0 14px 30px -16px --accent, overflow hidden. Two decorative circles: (a) absolute right -30 top -30, 150x150, radius999, rgba(255,255,255,.08); (b) right20 bottom -50, 120x120, rgba(255,255,255,.06). Label 13px weight600 opacity .85. Mode badge 12px weight700, bg rgba(255,255,255,.18), padding 4/10, radius999, capitalize. Net value: .num (--display, tabular-nums, ls -0.01em), 40px weight700, marginTop4, line-height 1.05. Inner tiles flex gap10 marginTop16: each flex1, bg rgba(255,255,255,.14), radius14, padding 10/12; tile label row gap6, 12px opacity .9 weight600 with Icon arrowDown/arrowUp size15 #fff; tile value .num 18px weight700 marginTop3.

### 3. SnapCTA (default variant 'feature')
Full-width dark CTA button. Left text column on --ink background with an 'AI auto-sort' sparkle pill, title 'Snap a receipt', subtitle; right 116px-wide accent-gradient panel with dotted texture + frosted camera tile.

_Components & tokens:_ marginTop 14. button width100%, radius --r-card 22, padding0, overflow hidden, flex stretch, bg --ink #211C18, --sh-card. Left pad 18/0/18/18: pill inline-flex gap6, bg rgba(255,255,255,.12), padding 4/10, radius999, marginBottom10, Icon sparkles size14 color --accent fill + text 11.5px weight700 #fff ls .2 'AI auto-sort'. Title 20px weight700 ls -0.3 lh1.1 #fff 'Snap a receipt'. Subtitle 13.5px rgba(255,255,255,.6) marginTop3 maxWidth180: "We'll read the total, GST & category for you." Right panel width116, bg linear-gradient(150deg, --accent, --accent-deep); dotted overlay opacity .25 radial-gradient dots 14x14; camera tile 60x60 radius20 bg rgba(255,255,255,.22) backdrop-blur(4px) Icon camera size30 #fff.

### 4. Quick actions row (mode-aware)
Four equal QuickAction columns. PERSONAL: Loyalty Card (star)->loyalty, Add Manually (plus)->manual, Mileage (car)->mileage, WFH log (wfh)->wfh. BUSINESS: Create Quote (doc)->quote, Add Manually (plus)->manual, Reports (chart)->reports, Receipts (receipt)->txns.

_Components & tokens:_ marginTop 18, flex gap6. Each QuickAction: flex1, column, gap7, centered. Icon tile 52x52 radius17, bg --paper, 1px --line, --sh-card; Icon size23 color --accent (active palette[0]). Label 11.5px weight600 --ink-2 centered lh1.15.

### 5a. Budgets card (PERSONAL only)
Card titled 'Monthly budgets' with 'Edit' accent link; three BudgetRows: Groceries 64.85/600, Eating out 18/200, Utilities 184.30/250 — all tinted --accent.

_Components & tokens:_ Card marginTop18, pad16, radius --r-card, bg --paper, 1px --line-2 #F3EBE1, --sh-card. Header flex space-between marginBottom12: title 15px weight700; 'Edit' 12.5px --accent weight600. BudgetRow (marginBottom14): label/amount row marginBottom7 baseline; label 13.5px weight600; amount .num 12.5px weight600, spent in --ink-3 (or --alert if over), '/ cap' span --ink-3; values via fmt(cents:false). Progress bar h8 radius999, track --line, fill tint (or --alert if spent>cap), width animates .6s cubic-bezier(.22,.61,.36,1).

### 5b. Deductible card (BUSINESS only)
Card titled 'Deductible · FY26' with green 'Tracked' shield pill; three BudgetRows: Software & subscriptions 576/800 (#7B5BD6), Vehicle & travel 735/650 (--accent, OVER -> alert state), Meals (50% rule) 142/300 (--income).

_Components & tokens:_ Card marginTop18, pad16. Header marginBottom14 gap8: title 'Deductible · FY26' 15px weight700; pill inline-flex gap4, 12px --income #1F9D6B weight700, bg --income-soft #DEF3E9, padding 4/9, radius999, Icon shield size13 --income, text 'Tracked'. BudgetRows as above; Vehicle row trips over state (spent 735 > cap 650) so amount + Progress fill render in --alert #D6452B.

### 6. Recent activity header
Row: 'Recent activity' title + 'See all >' link to txns tab.

_Components & tokens:_ marginTop20, flex space-between, padding 0 2px. Title 17px weight700 ls -0.3. Link button 13px --accent weight600, gap2, with Icon chevR size15 --accent. onClick -> go('txns').

### 7. Recent activity list (TxnRow x up to 4)
Card wrapping the 4 most recent txns for the active mode (m.slice(0,4)). Each row: category IconCircle + merchant + date(+AI badge) + signed amount.

_Components & tokens:_ Card marginTop10, pad '2px 14px'. Each TxnRow: flex gap12, full width, padding 12px 2px, borderBottom 1px --line-2 except last (none). IconCircle 42x42 radius13, bg category.soft, Icon category.icon size21 color category.tint sw1.9, fill=true only when cat==='income'. Merchant 14.5px weight600 ls -0.2 ellipsis. Sub-row 12.5px --ink-3 gap6: fmtDate(date) (e.g. '28 May') + if t.ai an inline AI badge (Icon sparkles size11 --accent fill + 'AI' --accent weight600). Amount .num 15px weight700, color --income if positive else --ink; fmt(amount, sign:true) so income shows leading '+', expenses leading '−' (U+2212 minus).

## Interactions
- **Tap TopBar profile area (only when profiles.length>1; else no-op, cursor default)** -> go('profilePicker') -> opens ProfilePickerSheet bottom sheet (shell overlay)
- **Tap bell button** -> go('alerts') -> opens AlertsSheet full-screen overlay
- **Tap SnapCTA (any variant; in 'tile' variant both sub-buttons)** -> go('capture') -> opens CaptureFlow overlay (VisionKit + OCR)
- **Tap QuickAction 'Add Manually'** -> go('manual') -> AddManualScreen overlay (passes mode; onSave prepends new txn)
- **Tap QuickAction 'Loyalty Card' (Personal)** -> go('loyalty') -> LoyaltyScreen overlay
- **Tap QuickAction 'Mileage' (Personal)** -> go('mileage') -> MileageScreen overlay (GPS auto-track is placeholder UI)
- **Tap QuickAction 'WFH log' (Personal)** -> go('wfh') -> WFHScreen overlay
- **Tap QuickAction 'Create Quote' (Business)** -> go('quote') -> CreateQuoteScreen overlay
- **Tap QuickAction 'Reports' (Business)** -> go('reports') -> switches to reports tab (setTab)
- **Tap QuickAction 'Receipts' (Business)** -> go('txns') -> switches to txns tab
- **Tap 'Edit' on Personal budgets card** -> Text link only — no handler wired in JSX (no onClick). Stub for budget editing; wire to budget editor in SwiftUI.
- **Tap 'See all' on Recent activity** -> go('txns') -> switches to txns tab
- **Tap a TxnRow** -> go('txn', t) -> setDetail(t) -> TxnDetail overlay for that transaction
- **Tab bar: tap Home/Activity/Reports/Profile** -> go(id) -> setTab; center FAB (camera) -> setOverlay('capture'). Tab bar lives in shell, floats over Home.
- **ProfileSwitcher component interactions (defined here but used on Profile screen, not Home): tap segment/pill** -> setActive(id) for <=2 profiles (segmented bar) or scroll pills for 3+; '+' pill -> go('addProfile'); 'menu' variant tap -> go('profilePicker'). ModeToggle setMode(m) maps to first profile of that type.

## States
- Default/populated: SEED data yields Personal recent = Woolworths Metro, Chemist Warehouse, Single Origin Roasters, Energy Australia; Business recent = The Grounds, Apple Final Cut, BP, Studio retainer income. Income/expense totals computed from txns filtered by mode.
- Empty (no txns for mode): JSX has no explicit empty branch on Home — recent list renders an empty Card and SummaryCard shows $0 net/income/expense. SwiftUI should add an EmptyArt-based empty state (EmptyArt primitive exists: 132px, accent-soft circle + receipt + plus badge) for the recent-activity card and zeroed summary.
- Loading: none on Home itself (data is in-memory SEED). In the real app this is local-first SwiftData read = effectively instant; show shimmer (sc-shimmer) skeleton only if a cold cloud pull is pending.
- Success: new txn saved via onSave prepends to list and Home recomputes income/expense and recent slice on next render (remount via key change replays stagger animation).
- Error: none modeled on Home. Sync/extract errors surface elsewhere (capture flow / offline queue).
- Budget over-cap state: when spent>cap (Business Vehicle & travel 735/650), amount text + Progress fill switch to --alert #D6452B.
- Unread-alerts state: bell always shows the accent unread dot in this design (static).

## Animations
- sc-fade-up (staggered children): each direct child of .stagger animates in on mount; .42s cubic-bezier(.22,.61,.36,1) both; from{opacity0,translateY(10px)} to{opacity1,translateY0}. Explicit animationDelay per section: TopBar 0ms, SummaryCard 80ms, SnapCTA 120ms, quick actions 160ms, budgets/deductible card 200ms, Recent header 240ms, Recent list card 280ms.
- sc-fade-up (screen-enter): whole HomeScreen wrapper animates on tab/profile change; .screen-enter = sc-fade-up .34s same easing. Remount keyed on tab+activeId.
- Progress width transition: budget/Progress bars animate width to pct over .6s cubic-bezier(.22,.61,.36,1) on render/value change.
- Segmented / ProfileSwitcher slider: transform .28s cubic-bezier(.22,.61,.36,1) when active segment changes (ModeToggle segmented + 2-profile bar); scroll-pill 'all .18s' on selection; ModeToggle underline indicator slides translateX .28s same easing.
- sc-rise: AlertsSheet (.3s) and ProfilePickerSheet (.32s) entry; cubic-bezier(.22,.61,.36,1) both; from translateY(14px) scale(.98).
- sc-fade: ProfilePickerSheet scrim/backdrop fade-in .25s.
- App-wide tokens available (used in capture/loyalty, not Home directly): sc-scan (capture scan line top 4%->92%), sc-pop-in (scale .5->1.08->1), sc-shimmer (skeleton background-position), sc-pulse, sc-check (stroke-dashoffset 48->0 checkmark), sc-ring (scale .6->1.5 fade), sc-confetti (translateY 220 rotate 420), sc-spin.

## Data fields
- READ per transaction (CATS + SEED schema): id, merchant (string), cat (key into CATS: meals/groceries/fuel/software/office/home/health/travel/income), amount (number; >0 income, <0 expense), date (ISO 'YYYY-MM-DD'), mode ('personal'|'business'), ai (bool -> shows AI sparkle badge). Also present in model though unused on Home row: tax (label), deductible (% e.g. 50/100), method (payment), note, gst (AUD GST amount), logbook ('vehicle').
- COMPUTED on Home: income = sum of positive amounts for mode; expense = sum of -amounts for negatives; net = income - expense; recent = first 4 of mode-filtered txns (already date-desc in SEED order).
- READ profile: profile.name, profile.initials, profile.palette ([0]=accent,[1]=soft,[2]=deep), profile.type; profiles[] (id, name, type, initials, palette); activeId; profiles.length (gates chevron + picker).
- Budget/deductible values are HARDCODED literals in JSX (Personal: Groceries 64.85/600, Eating out 18/200, Utilities 184.30/250; Business: Software 576/800, Vehicle 735/650, Meals 142/300). In v1 these must be backed by real budgets (SwiftData + push alerts) and a tax-deductible tracker derived from txn.deductible/gst, FY26, AU GST 10%.
- WRITTEN: onSave(tx) (from manual/capture) prepends {...tx, id:'n'+Date.now()} to txns; setActive(id) persists 'sc-active' to localStorage; setTab persists 'sc-tab'. In SwiftUI: writes hit SwiftData instantly + offline mutation queue; pull deltas via per-user cursor; last-write-wins on updatedAt; soft-delete tombstones.
- Formatters: fmt(n,{sign,cents}) -> AUD via en-AU toLocaleString, prefix '−'(U+2212) for negatives, '+' when sign && positive, '$' symbol; budgets/summary use cents:false. fmtDate(iso) -> en-AU 'd MMM' (e.g. '28 May'). fmtK for compact $k (not on Home).

## Components: TopBar (header: gradient avatar 46x46 r15, 'Active profile' label, name 19px, chevD pill, bell 44x44 r14 + accent unread dot), SummaryCard (accent gradient hero, net 40px .num, income/expense inner tiles), SnapCTA — variant 'feature' default (dark --ink card + 116px accent panel, camera tile, AI auto-sort pill); other variants 'gradient' (full accent gradient row + arrowRight) and 'tile' (two side-by-side: Snap receipt accent tile + Add manually paper tile), QuickAction (52x52 r17 paper icon tile + 11.5px caption), TxnRow (IconCircle + merchant + date/AI badge + signed .num amount), BudgetRow (label + spent/cap .num + Progress bar), Card primitive (bg --paper, r22, 1px --line-2, --sh-card, default pad16), IconCircle primitive (42x42 r13, soft bg, tinted icon), Progress primitive (h8 r999, animated fill), Icon primitive (24-grid line icons, sw1.85 default; classes icons-thin sw1.45 / icons-bold sw2.4), Segmented primitive (animated sliding pill) via ModeToggle, ModeToggle (segmented default; pills; underline variants) — Personal/Business with wallet/building icons, ProfileSwitcher (<=2 segmented bar; 3+ 'scroll' pills + dashed '+' or 'menu' compact pill with avatar stack) — used on Profile screen, TabBar (shell): floating glass bar r26 h64, blur(18px) saturate(180%), center 58x58 r20 accent-gradient FAB raised -26 with --sh-fab + 3px --cream border, AlertsSheet (shell overlay), ProfilePickerSheet (shell bottom sheet), EmptyArt (illustration primitive for empty states)
## Color tokens: --cream #FBF6F0, --paper #FFFFFF, --paper-2 #F6EEE4, --ink #211C18, --ink-2 #6B6258, --ink-3 #A99F93, --line #ECE3D8, --line-2 #F3EBE1, --p #E8602C, --p-soft #FDEBE0, --p-deep #C2461A, --b #0E7C72, --b-soft #DCF0ED, --b-deep #0A5950, --income #1F9D6B, --income-soft #DEF3E9, --alert #D6452B, --accent = active palette[0] (Personal #E8602C / Business #0E7C72), --accent-soft = active palette[1], --accent-deep = active palette[2], category meals tint #E8602C soft #FBEADF, groceries #C99A22 / #F6EECE, fuel #2F6FB0 / #E2ECF6, software #7B5BD6 / #EBE5F8, office #0E7C72 / #DCF0ED, home #B0568F / #F4E4EF, health #D6452B / #F8E2DD, travel #1F9D6B / #DEF3E9, income #1F9D6B / #DEF3E9, extra profile palettes: Lumen #3F5BB0/#E7EAF8/#2C4290, Rentals #2F7A55/#DFF0E6/#205B3D, white #FFFFFF text on accent/ink surfaces; rgba(255,255,255,.08/.06/.14/.18/.22/.12/.6/.85/.9) overlays, --sh-card 0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14), --sh-pop 0 8px 24px -8px rgba(33,28,24,.22), 0 2px 6px rgba(33,28,24,.08), --sh-fab 0 8px 20px -4px (accent 55% mix), 0 3px 8px rgba(33,28,24,.18), SummaryCard shadow 0 14px 30px -16px --accent, avatar shadow 0 6px 14px -6px palette[0], stage bg radial-gradient #F1ECE4->#E4DED5->#DAD3C9 (device backdrop, not in-app)

**Navigation:** Entry: mounted when tab==='home' (default). On tab/profile switch the wrapper replays sc-fade-up via .screen-enter (.34s) plus per-child staggered sc-fade-up (.42s, delays 0-280ms). Exit: navigations are overlay-based (capture/alerts/manual/loyalty/mileage/wfh/quote/profilePicker push full-screen or bottom-sheet overlays animated with sc-rise/sc-fade; Home stays mounted underneath) or tab swaps (Reports/Receipts/See all/profile change replace the keyed screen wrapper with a fresh sc-fade-up). TxnRow tap opens TxnDetail overlay. No native swipe-back gesture in the prototype; overlays close via their own back/scrim buttons.
**Notes:** FONTS: --display = Schibsted Grotesk (Google weights 400/500/600/700/800) used for numbers (.num: font-variant-numeric tabular-nums, letter-spacing -0.01em), avatar initials, and sheet titles; --ui = Hanken Grotesk (400/500/600/700) for all other UI text. Default system fallback system-ui. Map to bundled fonts in SwiftUI (Schibsted Grotesk for headings/amounts with monospacedDigit() + tracking -0.01em; Hanken Grotesk for body).

RADII: --r-card 22, --r-inner 16, --r-chip 12; pills/circles 999. Specific radii on Home: avatar 15, bell 14, summary inner tiles 14, snap camera tile 20 / right-panel none, quick-action tile 17, IconCircle 13, mode badge/pills 999.

DEVICE: 402x874 logical (IOSDevice frame from frames/ios-frame.jsx), content scaled to viewport (cap 1.18x) — for SwiftUI just target iPhone safe-area; top padding 54px corresponds to status-bar/notch clearance, bottom 124px clears floating tab bar.

ICON SET: 24x24 grid line icons (theme.jsx ICONS); used on Home: chevD, chevR, bell, camera, sparkles(fill), arrowDown, arrowUp, arrowRight, plus, star, car, wfh, doc, chart, receipt, shield, wallet, building, cup, cart, fuel, film, home, heart, pin. Default strokeWidth 1.85, round caps/joins; theme variants icons-thin 1.45 / icons-bold 2.4 (tweak panel, drop in v1). Replicate as SF Symbols or custom vector paths matching these d-strings for fidelity.

IMPORTANT IMPLEMENTATION NOTES: (1) HomeScreen's header uses TopBar (avatar + name + chevron + bell), NOT the ProfileSwitcher component — ProfileSwitcher/ModeToggle are defined in this file but consumed by the Profile screen; include them but they are not on the Home layout. (2) The design-only TweaksPanel and its variant switches (snapStyle, toggleStyle, iconStyle, multiStyle, profileCount, custom palettes) must be DROPPED in v1 — ship snapStyle='feature', toggleStyle='segmented', icon weight regular (1.85). (3) Budget/deductible numbers are placeholders in JSX — back them with real budgets + push alerts (build for real) and a tax-deductible tracker using AU GST 10% + per-txn deductible %. (4) Mileage GPS auto-track and connected-banks are PLACEHOLDER UI only. (5) Loyalty barcodes and budgets+push alerts are REAL v1 features. (6) Currency AUD, en-AU formatting; negatives use the Unicode minus '−' (U+2212), not hyphen. (7) Capture = on-device VisionKit + Vision OCR (reuse ReceiptScanner.swift) -> POST /extract -> DeepSeek deepseek-v4-flash JSON; email-in via Cloudflare. No emailed reminders — alerts stay in-app (AlertsSheet). (8) Sync local-first: SwiftData instant writes + offline queue, per-user cursor delta pull, last-write-wins on updatedAt, soft-delete tombstones; D1 + R2 source of truth; auth = Sign in with Apple + email magic-link.

OVERLAYS reachable from Home (defined in shell.jsx, summarized): AlertsSheet — full-screen --cream, sc-rise .3s, back button 40x40 r12, title 'Alerts' 16px/700, list of 4 alert Cards (IconCircle + title 14.5/700 + timestamp 11.5 --ink-3 + body 13 --ink-2); seeded alerts: GST quarter due (shield/income), 3 receipts auto-sorted (sparkles/accent), Subscription renewing (film/#7B5BD6), Budget check-in (wallet/--p). ProfilePickerSheet — bottom sheet r28 top corners, scrim rgba(20,16,12,.4) sc-fade, sc-rise .32s, 40x5 grabber, title 'Switch profile' 20px --display, subtitle, profile rows (42x42 gradient avatar + name 15.5/700 + type + check/empty radio, active row border palette[0]), dashed 'Add a profile' row.

---

# CaptureFlow (full-screen overlay, zIndex 80) containing 4 sequential stages: CameraStep, ScanStep, ReviewStep, SavedStep. Shared sub-component: ReceiptPaper (faux receipt). Sub-helper: field() (label/value/sub stack).

**Route:** Presented as a modal overlay over the shell when route 'capture' fires (TabBar center Snap FAB or go('capture')). State: overlay==='capture' in shell.jsx. Internal stage machine: step state in {'camera','scan','review','saved'}, initial 'camera'. onClose dismisses overlay (setOverlay(null)); onSave appends the txn to the shell's txns list (prepended with id 'n'+Date.now()).

**Purpose:** The capture centerpiece: snap a receipt in a camera viewfinder, watch an animated AI scan read fields one-by-one, review/edit AI-extracted fields with a "98% match" auto-categorize moment, then save with a confetti success. In the real app, on-device VisionKit capture + Vision OCR feeds POST /extract -> DeepSeek; here the data is hardcoded (The Grounds, $42.50, meals).

**Mode-aware:** Personal vs Business is the active-profile accent re-skin. --accent/--accent-soft/--accent-deep resolve to the active profile's palette[0/1/2]: PERSONAL = terracotta (--p #E8602C / --p-soft #FDEBE0 / --p-deep #C2461A), BUSINESS = teal (--b #0E7C72 / --b-soft #DCF0ED / --b-deep #0A5950). This recolors, in every stage: camera mode-pill leading dot + capitalized mode label; scan line gradient/glow + glow frame + found-chip border + check + spinner top color + sparkles; review AI banner gradient(135deg accent-soft->#fff)/border/'AI categorised'/98% badge text(accent-deep) + Save button bg & shadow; saved 'Snap another' button. The ModeToggle option tints are FIXED per option (Personal always wallet+--p, Business always building+--b) regardless of active accent. The seeded review content ('client coffee meeting', 'Business · Meals', 'Amex Business', 'Deductible 50%') is identical text in both modes — only the chroma changes. SavedStep summary sentence interpolates the live mode word ('added to Business expenses'). The green success circle/ring/check and the GST/income pill stay --income #1F9D6B in both modes (not accent-driven).

## Layout

### ReceiptPaper (shared faux receipt primitive)
White thermal-receipt card used in camera, scan, and review thumbnail. Centered text header 'THE GROUNDS' then subtitle 'OF ALEXANDRIA · SYDNEY'. Two dashed dividers. Line items: 'Flat White ×2' 9.00, 'Big Brekkie' 24.00, 'Sourdough' 9.50. 'GST incl.' 3.86 row. Bold 'TOTAL' / '$42.50' row. Footer '28 MAY 2026 · 09:41 · CARD •••• 1009'. Has a torn-bottom mask effect (perforated edge).

_Components & tokens:_ bg #fff, borderRadius 8, padding 18px 18px 22px, fontFamily Schibsted Grotesk (--display), color #2a2a2a. boxShadow 0 20px 50px -20px rgba(0,0,0,.6). maskImage linear-gradient(#000 92%, transparent) + repeating-linear-gradient(90deg,#000 0 8px,transparent 8px 16px) for torn/perforated look. Header: fontWeight 700, fontSize 15, letterSpacing 1. Subtitle: fontSize 9, color #888, marginTop 2. Dashed dividers: borderTop 1px dashed #ccc, margin 12px 0. Line item rows: flex space-between, fontSize 11, margin 6px 0, tabular-nums, nowrap. GST row: fontSize 10, color #888, tabular-nums. TOTAL row: fontWeight 700, fontSize 16, marginTop 8. Footer: fontSize 8.5, color #aaa, marginTop 14, centered.

### STAGE 1 — CameraStep viewfinder
Full-bleed dark camera mockup. Layered: (1) base radial-gradient feed, (2) subtle dot-grid texture overlay, (3) faux receipt placed on 'table' rotated -3deg, (4) top control row, (5) framing corner brackets, (6) hint text, (7) bottom capture bar.

_Components & tokens:_ Container: position absolute inset 0, bg #0c0a09, flex column. Feed: radial-gradient(120% 90% at 50% 40%, #2b2722 0%, #14110e 70%, #0a0807 100%). Texture: opacity .5, radial-gradient dot pattern, backgroundSize 22px 22px. Receipt: absolute top/left 50% translate(-50%,-50%) rotate(-3deg), width 168, opacity .96. Top row (zIndex 2): padding 56px 18px 0, flex space-between center. Three controls: close button (left) 40x40 radius 999 bg rgba(255,255,255,.14) backdrop blur(8px), Icon 'close' 20 #fff; center mode pill bg rgba(255,255,255,.14) blur(8px) radius 999 padding 7px 14px color #fff fontSize 13 weight 600, leading dot 7x7 radius 999 bg var(--accent) + capitalized mode text; flash button (right) same 40x40 style, Icon 'flash' 20 #fff. Framing corners: absolute centered box 230x320, four 30x30 L-shaped corner marks, border 3px solid rgba(255,255,255,.9), borderRadius 6. Hint: absolute bottom 188, centered, color rgba(255,255,255,.7), fontSize 13, weight 500, text "Line up your receipt — we'll auto-capture". Bottom bar (zIndex 2): absolute bottom 0, padding 0 0 46px, flex center gap 46. Gallery btn 50x50 radius 14 bg rgba(255,255,255,.14) blur(8px) Icon 'image' 24 #fff; shutter btn 78x78 radius 999 transparent border 4px solid rgba(255,255,255,.85) with inner 60x60 radius 999 #fff disc (transition transform .1s); doc/import btn 50x50 radius 14 same style Icon 'doc' 24 #fff.

### STAGE 2 — ScanStep (AI reading)
Dark screen, centered. Receipt with animated horizontal scan line sweeping top->bottom and a glowing accent frame. Below: sparkles icon + 'Reading your receipt…' heading. Below that: 5 field chips that flip from spinner (pending) to check (found) one-by-one.

_Components & tokens:_ Container: absolute inset 0, bg #0c0a09, flex column center center, padding 24. Receipt wrap: position relative width 196 (ReceiptPaper inside). Scan line: absolute left -4 right -4 height 3, background linear-gradient(90deg, transparent, var(--accent), transparent), boxShadow 0 0 16px 4px var(--accent), borderRadius 999, animation sc-scan 1.4s ease-in-out infinite alternate (top 4%->92%). Glow frame: absolute inset -10, border 2px solid var(--accent), borderRadius 12, opacity .5. Heading row: marginTop 30, flex center gap 9, color #fff: Icon 'sparkles' size 20 color var(--accent) fill, then span fontSize 17 weight 700 fontFamily --display 'Reading your receipt…'. Field chips: marginTop 18, flex wrap gap 8 justify center maxWidth 280. Order: ['Merchant','Date','GST','Total','Category']. Each chip: flex center gap 6, padding 7px 12px, radius 999, fontSize 12.5, weight 600, transition all .3s. Found state: bg rgba(255,255,255,.12), color #fff, border 1px solid var(--accent), leading Icon 'check' size 13 color var(--accent) sw 2.6. Pending state: bg rgba(255,255,255,.04), color rgba(255,255,255,.35), border 1px solid transparent, leading 11x11 radius 999 spinner border 2px solid rgba(255,255,255,.3) borderTopColor var(--accent) animation sc-spin .7s linear infinite.

### STAGE 3 — ReviewStep header
Light cream screen. Top bar: close button (left), 'Review receipt' title (center), edit button (right).

_Components & tokens:_ Container: absolute inset 0, bg var(--cream)=#FBF6F0, flex column. Header: padding 54px 18px 12px, flex space-between center. Close btn 40x40 radius 12 (--r-chip) bg var(--paper)=#FFF border 1px solid var(--line)=#ECE3D8, Icon 'close' 20 var(--ink-2)=#6B6258. Title: fontSize 17 weight 700 nowrap. Edit btn 40x40 radius 12 same style, Icon 'edit' 19 var(--ink-2).

### STAGE 3 — ReviewStep scroll body
Scrollable column (class scroll, padding 0 18px 120px) with staggered fade-up entrance per block: (1) receipt thumb + detected total + GST pill, (2) AI suggestion banner with 98% match, (3) details Card (Merchant/Date, Category row w/ chevron, Payment/Tax), (4) Assign-to-profile ModeToggle, (5) attach-extras chips.

_Components & tokens:_ BLOCK1 (anim sc-fade-up .4s both): flex gap 14 center. Thumb 64x84 radius 12 overflow hidden boxShadow --sh-card bg #fff, containing ReceiptPaper scaled transform scale(.34) origin top-left width 188. Right col: 'Total detected' fontSize 13 color var(--ink-3)=#A99F93 weight 600; amount '$42.50' class num fontSize 34 weight 700 lineHeight 1 marginTop 2; GST pill inline-flex gap 5 marginTop 6 bg var(--income-soft)=#DEF3E9 color var(--income)=#1F9D6B padding 3px 9px radius 999 fontSize 11.5 weight 700, Icon 'check' 12 var(--income) sw 2.6 + 'incl. $3.86 GST'. BLOCK2 AI banner (marginTop 16, anim sc-fade-up .4s .08s both): radius 16 (--r-inner) padding 14, background linear-gradient(135deg, var(--accent-soft), #fff), border 1px solid var(--accent). Row: Icon 'sparkles' 18 var(--accent) fill + 'AI categorised this for you' fontSize 13.5 weight 700 color var(--accent-deep) + right-aligned '98% match' badge fontSize 11 weight 700 color var(--accent-deep) bg #fff padding 3px 8px radius 999. Body p marginTop 8 fontSize 13 color var(--ink-2) lineHeight 1.45: "Looks like a [client coffee meeting] — filed under [Business · Meals], claimable at [50%]." (bold spans color var(--ink)). BLOCK3 details Card (marginTop 14, anim sc-fade-up .4s .14s both, Card pad '2px 16px', bg --paper, radius --r-card=22, shadow --sh-card, border 1px solid --line-2=#F3EBE1): Row1 flex padding 14px 0 borderBottom 1px solid var(--line-2): field('Merchant','The Grounds') + field('Date','28 May 2026'). Row2 (Category) flex center padding 14px 0 borderBottom 1px line-2: label 'Category' fontSize 11.5 color --ink-3 weight 600 marginBottom 5, then IconCircle name=cup tint #E8602C soft #FBEADF size 32 isize 17 + label 'Meals & Coffee' fontSize 15 weight 700, trailing Icon 'chevR' 18 var(--ink-3). Row3 flex padding 14px 0: field('Payment','Amex Business') + field('Tax','Client meeting', sub 'Deductible 50%'). field() helper: label fontSize 11.5 color --ink-3 weight 600 marginBottom 3; value fontSize 15.5 weight 700 letterSpacing -0.2; sub fontSize 11.5 color --ink-3 marginTop 1. BLOCK4 (marginTop 16, anim sc-fade-up .4s .2s both): 'Assign to profile' fontSize 13 weight 700 marginBottom 8 + ModeToggle. BLOCK5 (marginTop 14, anim sc-fade-up .4s .26s both): flex gap 8, two Chips: Icon 'car' 15 var(--ink-2) 'Add to mileage', Icon 'link' 15 var(--ink-2) 'Match to bank'.

### STAGE 3 — ReviewStep ModeToggle (Assign to profile)
Default variant is Segmented sliding control (animated). Two options: Personal (icon wallet, tint var(--p)) and Business (icon building, tint var(--b)). The active thumb slides; switching it changes the active profile and re-skins all --accent vars live.

_Components & tokens:_ Segmented: position relative, grid 2 cols 1fr, bg var(--paper-2)=#F6EEE4, radius 999, padding 4. Sliding thumb: absolute top/bottom 4 left 4, width calc((100%-8px)/2), translateX(idx*100%), bg var(--paper)=#FFF, radius 999, boxShadow 0 2px 6px -2px rgba(33,28,24,.18), transition transform .28s cubic-bezier(.22,.61,.36,1). Buttons: padding 9px 4px, fontSize 14, weight 600, letterSpacing -0.1, active color var(--ink), inactive var(--ink-3), flex center gap 6, transition color .2s; leading Icon size 16 colored to option tint when selected else var(--ink-3).

### STAGE 3 — ReviewStep save bar
Fixed bottom bar with gradient fade and a full-width primary Save button.

_Components & tokens:_ Bar: absolute bottom 0, padding 14px 18px 34px, background linear-gradient(transparent, var(--cream) 28%). Button onSave: width 100%, height 56, radius 18, bg var(--accent), color #fff, fontSize 17 weight 700, flex center gap 8, boxShadow 0 12px 24px -10px var(--accent), nowrap; content Icon 'check' 20 #fff sw 2.6 + 'Save receipt'.

### STAGE 4 — SavedStep success
Cream full-screen, centered. Confetti pieces fall from top. A green pulsing ring + popping circle with an animated drawn checkmark. 'Receipt saved!' heading + summary sentence. Two stacked buttons: 'Snap another' (primary accent) and 'Done' (paper outline).

_Components & tokens:_ Container: absolute inset 0, bg var(--cream), flex column center center, padding 30, overflow hidden. Confetti: 14 spans, absolute top 34%, left (8 + i*6.4)%, width 8 height 12 radius 2, colors cycle ['var(--accent)','var(--income)','#7B5BD6','#C99A22','#2F6FB0'][i%5], animation sc-confetti (1 + (i%5)*0.18)s delay (i%4)*0.06s ease-in forwards, opacity 0 initial. Badge wrap: relative 110x110 flex center. Ring: absolute inset 0 radius 999 bg var(--income), animation sc-ring 1.1s ease-out .1s (scale .6 opacity .55 -> scale 1.5 opacity 0). Circle: 96x96 radius 999 bg var(--income), flex center, animation sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both, boxShadow 0 14px 30px -10px var(--income). Check SVG 50x50 viewBox 0 0 24 24, path 'M5 12.5 10 17.5 19.5 7' stroke #fff strokeWidth 2.8 round caps, strokeDasharray 48, animation sc-check .5s .35s ease-out both (dashoffset 48->0, draws the tick). Heading: fontSize 24 weight 700 fontFamily --display marginTop 26, anim sc-fade-up .4s .4s both, text 'Receipt saved!'. Subtext p: fontSize 14.5 color var(--ink-2) center marginTop 6 lineHeight 1.45, anim sc-fade-up .4s .48s both: "$42.50 added to [mode] expenses,\nand tagged [50% deductible]." (mode capitalized + bold, '50% deductible' bold, both color var(--ink)). Buttons block: flex column gap 10 width 100% marginTop 30, anim sc-fade-up .4s .56s both. 'Snap another': height 54 radius 17 bg var(--accent) color #fff fontSize 16 weight 700 flex center gap 8, Icon 'camera' 20 #fff. 'Done': height 54 radius 17 bg var(--paper) border 1px solid var(--line) color var(--ink) fontSize 16 weight 700.

## Interactions
- **Tap close (X) button — any stage (camera top-left, review top-left)** -> onClose -> dismiss whole capture overlay (setOverlay(null)), returns to underlying shell screen
- **Tap flash button (camera top-right)** -> No handler wired (decorative in prototype); in SwiftUI rebuild: toggle torch
- **Tap gallery/image button (camera bottom-left)** -> No handler wired (decorative); in rebuild: open photo picker -> feed image to OCR
- **Tap doc/import button (camera bottom-right)** -> No handler wired (decorative); in rebuild: import file/PDF
- **Tap shutter button (camera center 78x78)** -> onShoot -> setStep('scan'); transitions to AI scanning stage. (Real app: VisionKit capture then on-device Vision OCR text -> POST /extract)
- **Scan completes (automatic timer, no user input)** -> After all 5 fields found + 500ms, onDone -> setStep('review')
- **Tap edit button (review top-right)** -> No handler wired (decorative); in rebuild: enter inline-edit mode for fields
- **Tap Category row (review details card, has chevR affordance)** -> No handler wired in prototype but visually a navigable row; in rebuild: open category picker that sets cat (state setCat exists, default 'meals'); changing cat updates IconCircle tint/soft + label live
- **Tap Personal / Business in ModeToggle (Assign to profile)** -> setMode(value) -> in shell switches active profile (setActive) -> active.palette changes -> --accent/--accent-soft/--accent-deep re-skin live (terracotta<->teal); the sliding thumb animates; AI banner gradient/border, 98% badge text, Save button, and all accent-tinted elements recolor
- **Tap 'Add to mileage' chip** -> No handler wired (decorative); placeholder UI in v1 (GPS mileage is UI-only placeholder)
- **Tap 'Match to bank' chip** -> No handler wired (decorative); placeholder UI in v1 (bank reconcile is UI-only placeholder)
- **Tap 'Save receipt' button (review)** -> onSave(txnObject) -> shell prepends new txn to txns list, then setStep('saved'). Saved txn fields below.
- **Tap 'Snap another' button (saved)** -> onAnother -> setStep('camera'); restarts the flow in the same overlay (fields re-detect from scratch)
- **Tap 'Done' button (saved)** -> onDone -> onClose -> dismiss overlay back to shell

## States
- CAMERA (idle/aiming): faux feed + framing corners + auto-capture hint; shutter ready. No real loading state — prototype has no autofocus/detection logic
- SCAN (loading): the genuine loading state. Progressive field detection — 5 chips start as spinners and flip to checkmarks one by one (Merchant 500ms, Date 860ms, GST 1220ms, Total 1580ms, Category 1940ms after mount), each via setTimeout(500 + i*360); scan line loops; total ~2.94s then auto-advance. In rebuild this maps to: OCR running -> /extract call -> fields populate
- REVIEW (success/populated): all fields extracted and shown editable; 98% match confidence banner; AI auto-categorised. This is the 'data ready' success-of-extraction state
- REVIEW (low-confidence variant — NOT in prototype): rebuild should handle when DeepSeek returns <high confidence or missing fields: badge would show lower %, fields blank/editable. Prototype hardcodes 98% match, all fields present
- SAVED (success): confetti + animated green check + summary; terminal success state
- ERROR (NOT in prototype): no error/offline state defined. Rebuild must add: OCR/extract failure, offline (local-first: save to SwiftData + offline mutation queue, sync later), no-receipt-detected. Empty state N/A — flow always has the seeded receipt

## Animations
- sc-fade (.25s both) — trigger: CaptureFlow overlay mount; opacity 0->1 for the whole overlay
- sc-scan (1.4s ease-in-out infinite alternate) — trigger: ScanStep mount; scan line top 4%->92% looping
- sc-spin (.7s linear infinite) — trigger: per pending field chip in ScanStep; spinner ring rotate 360deg
- field reveal (transition all .3s) — trigger: found count increments; each chip cross-fades from pending (dim, spinner) to found (lit, accent border, check icon). Driven by staggered setTimeouts not a keyframe
- sc-fade-up (.4s both, staggered delays) — trigger: ReviewStep blocks enter (0, .08s, .14s, .2s, .26s) and SavedStep text/buttons (.4s, .48s, .56s); translateY(10px)+opacity 0 -> settle
- Segmented thumb slide (transition transform .28s cubic-bezier(.22,.61,.36,1)) — trigger: ModeToggle selection change
- sc-confetti ((1+(i%5)*.18)s, delay (i%4)*.06s, ease-in forwards) — trigger: SavedStep mount; 14 pieces translateY 0->220px + rotate 0->420deg, opacity 1->0
- sc-ring (1.1s ease-out .1s) — trigger: SavedStep mount; success ring scale .6->1.5, opacity .55->0 (pulse-out halo)
- sc-pop-in (.5s cubic-bezier(.34,1.56,.64,1) both) — trigger: SavedStep mount; check circle scale .5->1.08->1 with opacity (spring overshoot)
- sc-check (.5s .35s ease-out both) — trigger: SavedStep mount; checkmark stroke-dashoffset 48->0 draws the tick
- shutter press (transition transform .1s) — trigger: camera shutter inner disc on press (subtle scale feedback)
- Defined-but-unused-in-this-screen keyframes (exist in stylesheet): sc-shimmer, sc-pulse, sc-rise

## Data fields
- READ (displayed, all hardcoded in prototype): merchant 'The Grounds', date '28 May 2026' (ISO 2026-05-28), total $42.50, gst $3.86, category 'meals' (label 'Meals & Coffee'), payment 'Amex Business', tax label 'Client meeting', deductible 50%, AI confidence '98% match', mode (active profile type personal|business)
- READ from CATS[cat]: label, icon, tint, soft — meals = {label:'Meals & Coffee', icon:'cup', tint:#E8602C, soft:#FBEADF}
- WRITTEN on Save (onSave object): {merchant:'The Grounds', cat:'meals', amount:-42.50, date:'2026-05-28', mode, tax:'Client meeting', deductible:50, method:'Amex Business', ai:true, gst:3.86}. Shell adds id:'n'+Date.now() and prepends to txns
- Scan stage field order (UI labels): Merchant, Date, GST, Total, Category
- Real-app mapping: amount negative = expense; mode from active profile; ai:true marks AI-extracted; gst is AU 10% GST; deductible is tax-deductible %. In rebuild these write to SwiftData immediately (local-first) + queue for D1/R2 sync

## Components: CaptureFlow (stage-machine container, zIndex 80), CameraStep, ScanStep, ReviewStep, SavedStep, ReceiptPaper (shared faux receipt), field() (label/value/sub helper), Card (theme primitive: bg paper, radius --r-card 22, shadow --sh-card, border 1px line-2), IconCircle (theme: size 32 isize 17, radius 13, soft bg + tinted icon — note radius is 13px not chip token), Chip (theme primitive: radius 999, padding 8px 14px, fontSize 13.5 weight 600, paper bg + line border when inactive), ModeToggle (home.jsx; default 'segmented' variant) -> Segmented (theme: sliding thumb), Segmented (theme: animated sliding control), Icon (theme: 24-grid line icons, default sw 1.85). Icons used: close, flash, image, doc, sparkles(fill), check(sw 2.6), chevR, edit, car, link, camera, cup(via IconCircle), building/wallet(ModeToggle)
## Color tokens: --cream #FBF6F0 (canvas), --paper #FFFFFF, --paper-2 #F6EEE4 (segmented track), --ink #211C18, --ink-2 #6B6258, --ink-3 #A99F93, --line #ECE3D8, --line-2 #F3EBE1 (card border + row dividers), --p #E8602C / --p-soft #FDEBE0 / --p-deep #C2461A (Personal accent), --b #0E7C72 / --b-soft #DCF0ED / --b-deep #0A5950 (Business accent), --accent / --accent-soft / --accent-deep = active palette[0/1/2] (runtime re-skin), --income #1F9D6B / --income-soft #DEF3E9 (GST pill + saved check ring/circle), --alert #D6452B (defined, unused in this screen), Camera darks: #0c0a09 (bg), radial #2b2722/#14110e/#0a0807, #2a2a2a/#888/#aaa/#ccc (receipt internals), rgba(255,255,255,.14/.85/.9/.7/.35/.3/.12/.05/.04) glass+text overlays, Confetti palette: var(--accent), var(--income), #7B5BD6, #C99A22, #2F6FB0, CATS.meals: tint #E8602C, soft #FBEADF, --sh-card 0 1px 2px rgba(33,28,24,.04),0 10px 26px -16px rgba(33,28,24,.14), ReceiptPaper shadow 0 20px 50px -20px rgba(0,0,0,.6); Save shadow 0 12px 24px -10px var(--accent); saved circle 0 14px 30px -10px var(--income)

**Navigation:** ENTRY: whole overlay container animates `sc-fade .25s both` (opacity 0->1) on mount. Stage transitions are instant swaps (conditional render, no cross-fade between steps) EXCEPT each new step's internal elements animate in. camera --(shutter tap onShoot)--> scan; scan --(auto, ~2.8s timer onDone)--> review; review --(Save tap onSave)--> saved; saved --(Snap another onAnother)--> camera, OR (Done onDone / close)--> overlay dismissed. EXIT: onClose at any stage dismisses overlay (no explicit exit animation defined; the overlay simply unmounts).
**Notes:** DEVICE 402x874; all px are at this base scale. The original is a stateless prototype with hardcoded extraction — for the SwiftUI iOS17+ rebuild wire: ReceiptScanner.swift (VisionKit + Vision OCR) for camera/scan stages; the scan stage's progressive field reveal should be driven by real OCR+/extract (DeepSeek deepseek-v4-flash JSON) progress, falling back to the staggered animation timing (~360ms steps) if instant. SwiftData write is synchronous/local-first on Save with offline queue; D1+R2 are source of truth (last-write-wins on updatedAt, soft-delete tombstones). Currency AUD, AU GST 10%, tax-deductible % logic are real. 'Add to mileage' and 'Match to bank' chips are PLACEHOLDER (UI-only) in v1. Drop nothing here (no Tweaks panel in this file). Fonts: Schibsted Grotesk (--display, numbers/headings, tabular-nums, letter-spacing -0.01em) weights 400-800; Hanken Grotesk (--ui) weights 400-700. NOTE the screenshots show wrapped line-item text ('Big Brekkie', 'Sourdough') because the narrow receipt width forces wrap despite whiteSpace nowrap on the row flex — in SwiftUI keep item rows single-line/truncating. The Category row carries a chevR but has no tap handler in the prototype; treat as the editable category picker entry point. SavedStep summary uses a literal <br/> line break.

---

# TransactionsScreen (Activity tab) + TxnDetail (full-screen transaction detail overlay). Defined in transactions.jsx; relies on primitives from theme.jsx (Card, IconCircle, Chip, EmptyArt, Icon, fmt, fmtDate, CATS), TxnRow from home.jsx, and ReceiptPaper from capture.jsx.

**Route:** Tab 'txns' in the bottom TabBar (label "Activity", icon "receipt"). Rendered via `tab === 'txns' && <TransactionsScreen txns mode go />`. Detail opens via `go('txn', t)` which sets `detail` state in App and renders `<TxnDetail t onClose />` as an absolute overlay above the tab content (z-index 70). No URL routing — pure state. Persisted: `localStorage 'sc-tab'` holds the active tab; `'sc-active'` holds active profile id.

**Purpose:** Activity is the searchable, filterable transaction ledger: users browse all receipts/income for the active profile, scoped by month, filtered by type (All/Expenses/Income), with a running count + net total, grouped by date with AI-sorted badges. TxnDetail is the read view of a single transaction showing category, amount, mode badge, AI badge, metadata rows (category, date, payment, GST, tax note, deductible %), attached receipt thumbnail (expenses only), and Edit/Delete actions.

**Mode-aware:** Both screens re-skin at runtime via accent vars = active profile palette[0/1/2]. Personal mode = terracotta (#E8602C / #FDEBE0 / #C2461A); Business mode = teal (#0E7C72 / #DCF0ED / #0A5950). This drives: month pill calendar icon, chevron-on-active states, picker active-row bg/text/check, active filter chips, AI badge sparkle+text, EmptyArt + CTA, FAB. List is pre-filtered to the active profile's mode (TransactionsScreen receives `mode` and does txns.filter(t => t.mode === mode)). In TxnDetail the mode badge pill is explicitly per-transaction (not active-profile): business -> background b-soft #DCF0ED, color b-deep #0A5950; personal -> background p-soft #FDEBE0, color p-deep #C2461A, label capitalized. Income transactions tend to be business (invoices/retainers) in seed data; income amounts always render in #1F9D6B regardless of mode. Note: detail mode badge uses the literal --b-soft/--b-deep/--p-soft/--p-deep tokens, while AI badge text uses the live --accent.

## Layout

### Device frame / safe area
Design device 402x874 pt (iPhone-class). Root background var(--cream) #FBF6F0. Screen scroll container fills height with top inset padding 54px (status bar / dynamic-island clearance) and bottom padding 124px (clears floating TabBar). Horizontal page padding 18px applied to the header block only; date groups use their own 18-20px insets. Scrollbars hidden (.scroll: overflow-y auto, no visible scrollbar).

_Components & tokens:_ container: padding 54px 0 124px, height 100%, overflow-y auto; inner header wrapper padding 0 18px; font-family default var(--ui)=Hanken Grotesk, color var(--ink) #211C18

### Header row: title + month pill
Flex row, space-between, align center. Left: H1 'Activity'. Right: month date-picker pill button (calendar icon + month label + chevron). Pill toggles a dropdown anchored below-right.

_Components & tokens:_ H1: font var(--display) Schibsted Grotesk, 30px, weight 700, letter-spacing -0.6px, margin 0, color #211C18. Pill button: height 42px, padding 0 12px 0 13px, radius 12 (var(--r-chip)), background var(--paper) #FFFFFF, border 1px solid var(--line) #ECE3D8, shadow var(--sh-card), gap 7px, font var(--ui) weight 700 size 13.5px color #211C18. Calendar icon name='calendar' size 18 color var(--accent). Label = month short+year e.g. 'May 2026' (en-AU {month:'short',year:'numeric'}), whiteSpace nowrap. Chevron icon name='chevD' size 15 color var(--ink-3) #A99F93, rotates 180deg when open (transition transform .2s).

### Month picker dropdown (conditional, pickerOpen)
On tap of pill: full-screen invisible scrim (fixed inset 0, z-index 5) closes on tap; popover (z-index 6) anchored top:50 right:0. Header label 'SELECT MONTH', then 8 month rows (current month + 7 prior, generated from new Date(2026, 4-i, 1) i=0..7 => May 2026 down to Oct 2025). Active month row highlighted with accent-soft bg + accent-deep text + trailing check icon.

_Components & tokens:_ popover: width 210px, background var(--paper), radius 16 (var(--r-inner)), shadow var(--sh-pop) = 0 8px 24px -8px rgba(33,28,24,.22),0 2px 6px rgba(33,28,24,.08), border 1px solid var(--line), padding 6px, animation sc-fade-up .2s both. Section label: 11.5px, color var(--ink-3), weight 700, uppercase, letter-spacing 0.3px, padding 6px 10px 8px. Row button: full-width flex space-between, padding 10px 12px, radius 10px, font 14.5px weight 600 var(--ui); active: background var(--accent-soft) color var(--accent-deep); inactive: transparent color var(--ink). Check icon name='check' size 16 color var(--accent) strokeWidth 2.6 (shown only on active row).

### Search field
Below header, margin-top 14px. Rounded input with leading search icon, placeholder 'Search merchant or category', and a trailing clear (x) button shown only when query non-empty. Filters list live by merchant + category label (case-insensitive substring).

_Components & tokens:_ container: flex align center gap 9px, background var(--paper), border 1px solid var(--line), radius 14px, padding 11px 14px, shadow var(--sh-card). Leading icon name='search' size 19 color var(--ink-3). Input: border none, transparent bg, flex 1, font var(--ui) 15px color var(--ink), placeholder color (browser default ink-3-ish). Clear: Icon name='close' size 17 color var(--ink-3).

### Filter chips (All / Expenses / Income)
Flex row gap 8px, margin-top 12px. Three Chip toggles; single-select via `kind` state ('all'|'expense'|'income'). Active chip filled with accent.

_Components & tokens:_ Chip primitive: inline-flex gap 6, padding 8px 14px, radius 999, font 13.5px weight 600 var(--ui), whiteSpace nowrap, transition all .18s. Active: background var(--accent), color #fff, border 1px solid var(--accent), shadow 0 4px 12px -6px rgba(33,28,24,.3). Inactive: background var(--paper), color var(--ink-2) #6B6258, border 1px solid var(--line), no shadow. Labels: All / Expenses / Income.

### Count + net total
Flex row space-between, align baseline, margin-top 16px. Left: '{n} transactions' count of filtered list. Right: 'Net {signed amount}' colored green when >=0 else ink.

_Components & tokens:_ Count: 13px, color var(--ink-3), weight 600. Net: class .num (var(--display), tabular-nums, letter-spacing -0.01em), 16px weight 700; color var(--income) #1F9D6B if total>=0 else var(--ink). Format fmt(total,{sign:true}) => uses '+'/'−' prefix + '$' + AUD-grouped 2dp (minus sign is U+2212 '−').

### Date-grouped transaction list OR empty state
If filtered list empty -> centered EmptyArt empty state. Otherwise: groups sorted by date descending; each group has a sticky-style day-label header then a Card containing TxnRow rows. Group margin-top 18px.

_Components & tokens:_ Group header (dayLabel): padding 0 20px 8px, 13px weight 700 color var(--ink-3). dayLabel logic vs reference 'today'=2026-05-29: diff 0 'Today', diff 1 'Yesterday', else en-AU {weekday:'long',day:'numeric',month:'long'} e.g. 'Wednesday 27 May'. Card: margin 0 18px, pad '2px 14px', background var(--paper), radius 22 (var(--r-card)), shadow var(--sh-card), border 1px solid var(--line-2) #F3EBE1.

### TxnRow (one transaction)
Full-width button row inside the Card: category IconCircle, merchant + date/AI sub-line, signed amount. Last row in a group drops the bottom divider.

_Components & tokens:_ button: flex align center gap 12, width 100%, text-align left, padding 12px 2px, borderBottom 1px solid var(--line-2) (none if last). IconCircle: size 42, radius 13, background = category.soft, Icon size 21 color = category.tint strokeWidth 1.9, fill=true only when cat==='income' (filled arrowDown). Merchant: 14.5px weight 600 letter-spacing -0.2px, ellipsis truncation. Sub-line: 12.5px color var(--ink-3) margin-top 1, contains fmtDate(date) (en-AU default {day:'numeric',month:'short'} e.g. '28 May') and, if t.ai, an inline AI badge: sparkles icon size 11 color var(--accent) fill + ' AI' text color var(--accent) weight 600. Amount: class .num 15px weight 700, color var(--income) if income else var(--ink); fmt(amount,{sign:true}).

### Empty state (list length 0)
Centered column, padding 40px 30px, text-align center. EmptyArt illustration, headline, body copy, and a primary 'Snap a receipt' CTA that opens capture.

_Components & tokens:_ EmptyArt: 132x132 SVG — circle r60 fill var(--accent-soft), tilted receipt card (white, accent stroke 2.4, rotate -6deg) with faint accent ledger lines opacity .55, and an accent plus-badge circle (r17 fill var(--accent), white + sign). Headline 'Nothing here yet' 18px weight 700 margin-top 14 whiteSpace nowrap. Body 'No matches for this filter. Snap a receipt to add your first one.' 14px color var(--ink-2) margin-top 4 line-height 1.45. CTA button: margin-top 16, padding 12px 22px, radius 14, background var(--accent), color #fff, weight 700 15px, flex gap 8, camera icon size 18 white + 'Snap a receipt'.

## Interactions
- **Tap month pill button** -> Toggle pickerOpen; chevron rotates 180deg (.2s); dropdown appears with sc-fade-up .2s
- **Tap a month row in dropdown** -> setMonthKey(key) + close dropdown; list re-filters to that YYYY-MM (t.date.slice(0,7)===monthKey)
- **Tap scrim behind open dropdown** -> Close dropdown (setPickerOpen(false))
- **Type in search input** -> setQ; list filters live on (merchant + ' ' + category label).toLowerCase().includes(q.toLowerCase())
- **Tap clear (x) in search** -> setQ('') resetting search; clear button only visible while q non-empty
- **Tap a filter chip (All/Expenses/Income)** -> setKind; Expenses keeps amount<0, Income keeps amount>0, All keeps both; chip becomes filled accent
- **Tap a TxnRow** -> go('txn', t) -> App.setDetail(t) opens TxnDetail full-screen overlay (sc-rise .3s)
- **Tap 'Snap a receipt' CTA in empty state** -> go('capture') -> opens capture overlay
- **TxnDetail: tap back (arrowLeft) button** -> onClose -> App.setDetail(null), overlay dismissed
- **TxnDetail: tap dots (overflow) button** -> No handler in prototype (placeholder; intended action menu). Rebuild: present action menu/sheet.
- **TxnDetail: tap 'Receipt attached' card (expenses only)** -> No handler in prototype; copy says 'Tap to view full image'. Rebuild: open full receipt image viewer.
- **TxnDetail: tap Edit button** -> No handler in prototype (placeholder). Rebuild: open edit form.
- **TxnDetail: tap Delete button** -> No handler in prototype (placeholder). Rebuild: confirm + soft-delete (tombstone) per local-first sync.
- **Vertical scroll of list / detail body** -> Standard scroll; scrollbars hidden

## States
- List populated: date-grouped Cards of TxnRows; count + net header reflect current filters
- Empty (no matches): EmptyArt + 'Nothing here yet' + body + 'Snap a receipt' CTA (triggered when month/kind/search filters yield 0 rows)
- No loading state in prototype (seed data is synchronous). Rebuild from SwiftData/local-first: show shimmer/sc-shimmer skeleton rows while pulling deltas; list renders instantly from local cache (local-first writes)
- No error state in prototype. Rebuild: surface sync/offline errors non-blockingly (e.g. banner), keep showing cached local data
- TxnDetail expense vs income: income hides the receipt-attached card; expense shows it
- TxnDetail optional metadata rows render conditionally: GST row only if t.gst != null; Tax note only if t.tax; Deductible only if t.deductible != null
- Search clear button: visible only when q non-empty
- Month picker active-row state: highlighted bg + check icon on selected month

## Animations
- sc-fade-up (.2s both): month picker dropdown entrance — opacity 0->1, translateY 10px->0
- sc-fade-up (.34s cubic-bezier(.22,.61,.36,1) both): screen-enter — whole Activity screen fades/slides in on tab switch (keyed by tab+activeId)
- Chevron rotate: month pill chevron transform rotate(0->180deg) transition .2s on open/close
- Chip transition all .18s when toggling active/inactive
- sc-rise (.3s cubic-bezier(.22,.61,.36,1) both): TxnDetail overlay entrance — opacity 0->1, translateY 14px->0 + scale .98->1
- (Available but not used directly on these screens) sc-scan, sc-pop-in, sc-shimmer, sc-pulse, sc-check, sc-ring, sc-confetti, sc-spin, sc-fade live in the global stylesheet for capture/success flows

## Data fields
- READ txns[] (App state, seeded from SEED in theme.jsx; in rebuild = SwiftData @Query)
- READ mode (active profile type: 'personal'|'business') — list pre-filtered to t.mode === mode
- Transaction fields READ: id, merchant (string), cat (category key into CATS), amount (number; <0 expense, >0 income), date (ISO 'YYYY-MM-DD'), mode ('personal'|'business'), method (payment string e.g. 'Amex Business','Visa •2241','Apple Pay','Bank transfer','Direct debit'), ai (bool -> AI badge), gst (number, nullable; AU 10% GST included amount), tax (string note e.g. 'Client meeting','Invoice #1042', nullable), deductible (number %, nullable), note (string, present in seed but NOT displayed), logbook (e.g. 'vehicle', present in seed but NOT displayed here)
- CATS[cat] READ: label, icon, tint (hex), soft (hex)
- Derived/computed (not persisted): filtered list, total = sum(amount), groups = groupByDate, count = list.length, dayLabel, monthKey ('2026-05' default), MONTHS list
- WRITES on these screens: none persistent in prototype (kind, q, monthKey, pickerOpen are local UI state). Edit/Delete are placeholders. Rebuild: Delete = soft-delete tombstone + queue; Edit = mutate fields + bump updatedAt (last-write-wins). Add updatedAt/deletedAt/userId fields for sync.

## Components: Card (theme.jsx): background paper, radius 22, shadow sh-card, border 1px line-2, default pad 16 (overridden to '2px 14px' for list groups, 16 for detail receipt card, '2px 16px' for detail metadata card), IconCircle (theme.jsx): square size param (42 in rows, 62 in detail), radius 13, soft bg, tint icon, fill flag for income, Chip (theme.jsx): pill toggle filter, accent fill when active, EmptyArt (theme.jsx): 132x132 friendly receipt+plus SVG tinted with accent, Icon (theme.jsx): 24-grid line icons, default strokeWidth 1.85, fill flag — used: calendar, chevD, search, close, check, sparkles, camera, arrowLeft, dots, chevR, pencil, trash; category icons cup/cart/fuel/film/building/home/heart/pin/arrowDown, TxnRow (home.jsx): one transaction button row, ReceiptPaper (capture.jsx): faux thermal receipt; in detail shown scaled to 0.3 (transform scale(.3), origin top-left, source width 188) inside a 56x74 rounded(10) white clipped thumbnail with sh-card, detailRow helper (transactions.jsx): label/value pair row, padding 14px 0, borderBottom 1px line-2; label 14px ink-2 weight 500, value 14.5px weight 700 (color overridable), TabBar (shell.jsx): persistent bottom nav with center FAB snap button (58x58, radius 20, gradient accent->accent-deep, shadow sh-fab, 3px cream border)
## Color tokens: cream/canvas #FBF6F0, paper #FFFFFF, paper-2 #F6EEE4, ink #211C18, ink-2 #6B6258, ink-3 #A99F93, line #ECE3D8, line-2 #F3EBE1, income #1F9D6B, income-soft #DEF3E9, alert #D6452B, personal accent p #E8602C / p-soft #FDEBE0 / p-deep #C2461A (terracotta), business accent b #0E7C72 / b-soft #DCF0ED / b-deep #0A5950 (teal), accent/accent-soft/accent-deep = active profile palette[0/1/2] (re-skins live; Personal=terracotta, Business=teal; also Lumen #3F5BB0/#E7EAF8/#2C4290, Rentals #2F7A55/#DFF0E6/#205B3D), category meals #E8602C/#FBEADF, groceries #C99A22/#F6EECE, fuel #2F6FB0/#E2ECF6, software #7B5BD6/#EBE5F8, office #0E7C72/#DCF0ED, home #B0568F/#F4E4EF, health #D6452B/#F8E2DD, travel #1F9D6B/#DEF3E9, income cat #1F9D6B/#DEF3E9, white #FFFFFF (CTA/icon-on-accent text), minus sign uses U+2212 '−' not hyphen

**Navigation:** Entry: selecting the 'Activity' tab in the bottom TabBar swaps `tab` to 'txns'; the screen container animates with `screen-enter` = sc-fade-up .34s cubic-bezier(.22,.61,.36,1). Exit to detail: tapping a row calls go('txn', t) which sets App `detail`, rendering TxnDetail as an absolute overlay (inset 0, z-index 70) over the tab content with sc-rise .3s; the TabBar remains mounted beneath. Return: back button calls onClose -> setDetail(null), removing the overlay (no explicit exit animation in prototype — appears/disappears). Empty-state CTA navigates to the capture overlay via go('capture').
**Notes:** TxnDetail layout (full-screen overlay, var(--cream) bg, z-index 70, sc-rise .3s): (1) Top bar padding 54px 18px 12px, flex space-between: back button 40x40 radius 12 paper + 1px line, arrowLeft icon 20 ink-2; center title 'Transaction' 16px weight 700; right dots button identical style. (2) Scroll body padding 0 18px 110px. (3) Hero centered column padding 8px 0 18px: IconCircle size 62 isize 30 (radius 13, soft bg, tint icon, fill if income); merchant 19px weight 700 margin-top 12; amount class .num 38px weight 700 margin-top 2, color income #1F9D6B else ink, fmt(amount,{sign:true}); badge row gap 8 margin-top 10 — mode pill (12px weight 700, padding 5px 11px, radius 999, mode-colored as above, capitalize) + AI pill if t.ai (inline-flex gap 4, 12px weight 700, padding 5px 11px, radius 999, background paper + 1px line, color var(--accent), sparkles icon size 12 fill + 'AI sorted'). (4) Metadata Card pad '2px 16px' with detailRows: Category=CATS[cat].label; Date=fmtDate(date,{weekday:'short',day:'numeric',month:'long',year:'numeric'}) e.g. 'Thu, 28 May 2026'; Payment=t.method; 'GST included'=fmt(t.gst) if gst!=null (note: a gst of 0, e.g. groceries/health/personal items, IS shown since 0 != null -> displays '$0.00'); 'Tax note'=t.tax if present; 'Deductible'=deductible+'%' colored var(--income) if deductible!=null. (5) Receipt card (expenses only, !income) pad 16 margin-top 14: 56x74 radius-10 white thumbnail (ReceiptPaper scaled .3 from 188px width, sh-card) + 'Receipt attached' 14px weight 700 / 'Tap to view full image' 12.5px ink-3 + chevR icon 18 ink-3. (6) Action row gap 10 margin-top 16: two equal buttons height 50 radius 15 paper +1px line weight 700 14.5px — Edit (pencil 18 ink-2) and Delete (trash 18 alert, text color var(--alert) #D6452B). Fonts: --display 'Schibsted Grotesk' (weights 400-800 available) for numbers/headings via .num/.display (tabular-nums, letter-spacing -0.01em); --ui 'Hanken Grotesk' (400-700) for all UI text. Radii tokens: r-card 22, r-inner 16, r-chip 12, pills/circles 999. Shadows: sh-card=0 1px 2px rgba(33,28,24,.04),0 10px 26px -16px rgba(33,28,24,.14); sh-pop=0 8px 24px -8px rgba(33,28,24,.22),0 2px 6px rgba(33,28,24,.08); sh-fab=0 8px 20px -4px color-mix(accent 55%),0 3px 8px rgba(33,28,24,.18). Reference 'today' for dayLabel is hardcoded 2026-05-29 (use real Date in rebuild). Default monthKey '2026-05'. For SwiftUI: use Dynamic Type-friendly fixed sizes per spec, AUD currency formatting (en-AU, '$', grouping, 2dp; render negatives with U+2212), tabular figures for all numerics. Source files: /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/transactions.jsx (primary), theme.jsx (primitives/tokens/CATS/SEED), home.jsx:275 (TxnRow), capture.jsx:5 (ReceiptPaper), shell.jsx (routing/go), snapceipt.html (CSS tokens + @keyframes).

---

# ReportsScreen (tab="reports") + ExportSheet (bottom-sheet overlay, route "export"). Both defined in reports.jsx; helper StatPill is a private sub-component.

**Route:** Mounted by shell.jsx when tab==='reports' as &lt;ReportsScreen txns mode go /&gt;. Export sheet mounted when overlay==='export' as &lt;ExportSheet onClose /&gt;. go('export') sets overlay='export'; go('mileage')/go('wfh') open MileageScreen/WFHScreen overlays (logbook-pages.jsx). Tab bar (shell.jsx) is the global entry; Reports is the 4th tab (icon 'chart').

**Purpose:** Reports tab: summarises the active profile's finances — income-vs-expense 5-month trend (BarPair), category spend breakdown (Donut + legend), and (Business mode only) tax stat cards (Deductible YTD, GST on purchases) plus Vehicle/WFH logbook rows; (Personal mode only) an "under budget" encouragement card; always an AI insight card. The Export button opens ExportSheet, a bottom sheet to generate/send a tax-ready PDF/CSV/accountant package.

**Mode-aware:** Personal vs Business differ substantially. ACCENT re-skins at runtime from active profile palette: Personal accent --accent #E8602C / --accent-soft #FDEBE0 / --accent-deep #C2461A (terracotta); Business --accent #0E7C72 / --accent-soft #DCF0ED / --accent-deep #0A5950 (teal). This recolors: Export pill + its shadow, BarPair expense bars, 'Out' legend dot, GST stat-pill icon, AI insight gradient/border/label, ExportSheet selected tiles + CTA + sparkle. BUSINESS-ONLY blocks: the two tax StatPills (Deductible YTD, GST on purchases) and the Logbooks section (Vehicle + WFH rows). PERSONAL-ONLY block: the 'You're under budget' star card. AI insight body copy is mode-specific (software/subscriptions vs groceries/budget). Note other profiles exist (Lumen #3F5BB0, Rentals #2F7A55) all type 'business' — so business layout applies for any non-personal profile, just with that profile's palette.

## Layout

### Scroll container
Full-height vertical scroll (.scroll, momentum, hidden scrollbar). Background inherits app --cream #FBF6F0. Padding 54px top / 18px sides / 124px bottom (bottom clears the floating tab bar). Children animate in via .screen-enter (sc-fade-up) at the shell level on tab/profile change.

_Components & tokens:_ div.scroll; padding:54px 18px 124px; font-family --ui (Hanken Grotesk); color --ink #211C18

### Header row
Flex row, space-between, centered. Left: H1 'Reports'. Right: Export pill button with up-arrow share icon + label, accent-filled.

_Components & tokens:_ h1: font-family --display (Schibsted Grotesk), 30px, weight 700, letter-spacing -0.6px, margin 0. Export button: padding 10px 14px, radius 12px, background var(--accent) (personal #E8602C / business #0E7C72), color #fff, weight 700, fontSize 13.5px, gap 6px, boxShadow '0 8px 18px -8px var(--accent)'; Icon name='share' size 17 color #fff.

### Period Segmented control
marginTop 14px. Animated sliding segmented control with 3 options: Month / Quarter / FY (values month|quarter|year). Default 'month'. The sliding pill animates between segments. NOTE: in this prototype changing period does NOT recompute data (all figures are from full txns set + static TREND); it is purely visual selection state.

_Components & tokens:_ Segmented (theme.jsx): container background var(--paper-2) #F6EEE4, radius 999, padding 4px, grid 3 equal cols. Slider thumb: background var(--paper) #FFFFFF, radius 999, boxShadow '0 2px 6px -2px rgba(33,28,24,.18)', transform translateX(idx*100%), transition transform .28s cubic-bezier(.22,.61,.36,1). Labels fontSize 14, weight 600, letter-spacing -0.1; active color var(--ink) #211C18, inactive var(--ink-3) #A99F93, color transition .2s.

### Income-vs-expense trend Card
marginTop 16px, pad 18. Top flex row space-between/align flex-start: LEFT block = caption 'Net saved · last 5 months' + big net number (income−expTotal computed from txns of active mode); RIGHT = legend (green dot 'In', accent dot 'Out'). Below: BarPair chart of static TREND (Jan–May income/expense).

_Components & tokens:_ Card: background --paper #FFFFFF, radius --r-card 22px, border 1px solid --line-2 #F3EBE1, boxShadow --sh-card (0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14)). Caption: 13px, weight 600, color --ink-3 #A99F93, nowrap. Net number: .num (display font, tabular-nums, letter-spacing -0.01em) 28px weight 700 letter-spacing -0.5px, marginTop 2px; rendered via fmt(value,{cents:false}) e.g. '$3,835'. Legend: gap 12, fontSize 11.5, weight 600; dots 9x9 radius 3 — In = --income #1F9D6B, Out = --accent. BarPair wrapper marginTop 16.

### BarPair chart
height 120px, flex-end aligned, gap 14 between months, padding 0 2px. Each month = column: a 98px-tall (height-22) bar group (gap 4, align flex-end) holding two 11px-wide rounded bars (income green, expense accent), radius 5, with a month label below.

_Components & tokens:_ theme.jsx BarPair: max = max of all income/expense (≥1). income bar background --income #1F9D6B; expense bar background --accent; width 11px, borderRadius 5px, height = (value/max)*(120-22), transition height .6s. Label fontSize 11, weight 600, color --ink-3 #A99F93. Data static TREND: Jan{4800,3100} Feb{5200,2700} Mar{4100,3600} Apr{6050,2900} May{5050,2480}.

### Donut category breakdown Card
marginTop 14px, pad 18. Title 'Where it went' (15px/700). Below: flex row gap 18 — LEFT Donut (size 140, thickness 20) with centered total spend (fmtK e.g. '$1.2k') over caption 'spent'; RIGHT legend list of top 5 categories (slice(0,5)) each: color dot + label (ellipsis) + value (fmtK).

_Components & tokens:_ Card as above. Title 15px weight 700 marginBottom 4. Donut center: .num 22px weight 700 letter-spacing -0.5 ('$1.2k'); 'spent' 11px weight 600 color --ink-3. Legend rows: marginBottom 9, gap 8; dot 9x9 radius 3 background = category tint; label 12.5px weight 600 flex1 ellipsis; value .num 12.5px weight 700 color --ink-2 #6B6258.

### Donut SVG primitive
SVG rotated -90deg. Track circle stroke --line #ECE3D8 full ring. Each segment is a circle with strokeDasharray '(len-3) C' (3px gap between arcs), strokeLinecap round, strokeDashoffset -accumulated, animated stroke-dasharray .7s cubic-bezier(.22,.61,.36,1). r=(size-thickness)/2=60, thickness 20.

_Components & tokens:_ theme.jsx Donut; segments derived from expenses grouped by cat, sorted desc by value; each seg tint = CATS[cat].tint. Center children overlaid absolutely, column centered.

### BUSINESS-ONLY: Tax stat pills row
marginTop 14, flex row gap 10. Two equal StatPill cards: 'Deductible YTD' (shield icon, --income tint, value fmtK(deductible)) and 'GST on purchases' (receipt icon, --accent tint, value fmtK(gst)).

_Components & tokens:_ StatPill = Card pad 14, flex 1. Icon size 20 color = tint (income #1F9D6B / accent). Value .num 22px weight 700 marginTop 8 letter-spacing -0.5. Label 12px color --ink-3 weight 600 marginTop 1.

### BUSINESS-ONLY: Logbooks section
Section header 'Logbooks' (17px/700, letter-spacing -0.3, margin 20px 2px 10px). One Card (pad '2px 16px') containing 2 tappable rows: 'Vehicle logbook' (car icon, blue #2F6FB0/#E2ECF6, sub '342 km · 12 trips this month', value $215, route mileage) and 'Working from home' (wfh icon, teal #0E7C72/#DCF0ED, sub '68 hrs logged · fixed rate', value $45.56, route wfh). All values are static strings.

_Components & tokens:_ Row button: flex, gap 12, full width, textAlign left, padding 14px 0, borderBottom 1px solid --line-2 except last (none). IconCircle size 42 radius 13 soft bg, inner Icon. Title 14.5px weight 700; sub 12.5px color --ink-3 marginTop 1. Value .num 14.5px weight 700 color --income #1F9D6B. Trailing Icon chevR size 17 color --ink-3.

### PERSONAL-ONLY: Under-budget Card
marginTop 14, pad 18. Flex row gap 10: filled star IconCircle (accent) + text block: title 'You're under budget' + sub 'Spending is 18% lower than April. Nice work.' (static copy).

_Components & tokens:_ IconCircle name='star' tint var(--accent) size 40 isize 20 fill=true (filled glyph). Title 14.5px weight 700; sub 12.5px color --ink-3 marginTop 1.

### AI insight Card (always)
marginTop 14, pad 16. Gradient card with accent border. Header row: filled sparkles icon + 'Snapceipt insight' label. Body paragraph differs by mode (business = software/subscriptions copy; personal = groceries/budget copy).

_Components & tokens:_ Card override: background linear-gradient(135deg, var(--accent-soft), #fff), border 1px solid var(--accent). Icon name='sparkles' size 18 color --accent fill=true. Label 13.5px weight 700 color --accent-deep (#C2461A personal / #0A5950 business), gap 8. Paragraph: margin '8px 0 0', 13.5px color --ink-2 #6B6258, lineHeight 1.45. Business text: 'Software is your fastest-growing category. 3 subscriptions renew next week — total $653.' Personal text: 'Groceries are trending down this month. At this rate you'll save ~$120 vs your budget.'

### OVERLAY ExportSheet — scrim
position absolute inset 0, zIndex 75, column justify flex-end. Full-screen tap-to-dismiss scrim.

_Components & tokens:_ Scrim div: background rgba(20,16,12,.4), animation sc-fade .25s both; onClick=onClose.

### OVERLAY ExportSheet — sheet body
Bottom sheet anchored to bottom. Grabber handle, title 'Export & send', subtitle, 3 format selector tiles, a 3-row detail Card, and a full-width primary CTA.

_Components & tokens:_ Sheet: background --cream #FBF6F0, borderRadius '28px 28px 0 0', padding '12px 18px 38px', animation sc-rise .32s cubic-bezier(.22,.61,.36,1) both. Grabber: 40x5 radius 999 background --line #ECE3D8, margin '0 auto 16px'. Title: --display font, 20px weight 700. Subtitle: 13.5px color --ink-2, margin '4px 0 16px', text 'Tax-ready summary with all receipts attached.'

### ExportSheet — format selector tiles
Flex row gap 10. 3 equal tiles: pdf/doc icon/'PDF report' (default selected), csv/film icon/'CSV file', accountant/share icon/'To accountant'. Selecting toggles fmtSel state and re-skins the tile.

_Components & tokens:_ Tile button flex1, padding '16px 8px', radius 16, column centered gap 8. Selected: background --accent-soft, border 1px solid --accent, icon color --accent, label color --accent-deep. Unselected: background --paper #FFFFFF, border 1px solid --line #ECE3D8, icon color --ink-2, label color --ink-2. Icon size 24. Label 12.5px weight 700.

### ExportSheet — detail Card
marginTop 14, pad '2px 16px'. 3 label/value rows (first two with bottom divider): Period = 'FY 2025–26'; Receipts included = '48 images'; Deductible total = '$1,287.40' (green). All static strings.

_Components & tokens:_ Card. Row: flex space-between padding '13px 0', borderBottom 1px solid --line-2 #F3EBE1 (none on last). Label 14px color --ink-2; value 14px weight 700; deductible value adds .num + color --income #1F9D6B.

### ExportSheet — CTA
Full-width primary button 'Generate & send' with share icon. In prototype it just calls onClose (no real export).

_Components & tokens:_ Button: width 100%, height 54, marginTop 16, radius 17, background --accent, color #fff, 16px weight 700, centered, gap 8. Icon name='share' size 19 color #fff.

## Interactions
- **Tap Export pill in header** -> go('export') -> shell sets overlay='export' -> ExportSheet mounts with sc-fade scrim + sc-rise sheet animation.
- **Tap a Segmented option (Month/Quarter/FY)** -> setPeriod(value); slider thumb animates (transform .28s) to the chosen segment; active/inactive label colors crossfade (.2s). No data recompute in prototype.
- **Tap Vehicle logbook row (business)** -> go('mileage') -> shell overlay='mileage' -> MileageScreen opens (logbook-pages.jsx).
- **Tap Working-from-home row (business)** -> go('wfh') -> shell overlay='wfh' -> WFHScreen opens (logbook-pages.jsx).
- **Scroll the screen** -> Vertical momentum scroll; scrollbar hidden; content above tab bar (124px bottom pad).
- **ExportSheet: tap scrim (dim background)** -> onClose -> overlay=null, sheet dismissed.
- **ExportSheet: tap a format tile (PDF/CSV/accountant)** -> setFmt(key); selected tile re-skins to accent-soft bg + accent border + accent-deep label; previously selected reverts.
- **ExportSheet: tap 'Generate & send' CTA** -> onClose -> overlay=null (prototype stub; in v1 should trigger PDF/CSV generation or send-to-accountant email).
- **Tab bar Reports icon (global)** -> go('reports') -> setTab('reports'); screen re-mounts with .screen-enter sc-fade-up animation.

## States
- Loaded/success (default): all sections render from txns of active mode; charts animate in.
- Empty (business): if no expenses, Donut shows only the grey track ring (--line), center total '$0', legend empty; deductible/GST pills show '$0'. Trend BarPair always renders (static TREND, never empty).
- Empty (personal): same Donut/legend empties; under-budget card and AI insight still render (static copy).
- Loading: none implemented — data is synchronous from in-memory txns; in SwiftUI rebuild, wrap chart/aggregate reads in a loaded state and show skeletons (sc-shimmer) while SwiftData query resolves.
- Error: none in prototype; for real export add failure toast/retry on Generate & send.
- ExportSheet open/closed: controlled by overlay==='export'; open animates sc-rise + sc-fade scrim, close unmounts.

## Animations
- sc-fade-up (.34s cubic-bezier(.22,.61,.36,1)) — screen mount via .screen-enter when Reports tab/profile changes.
- Segmented slider — transform translateX .28s cubic-bezier(.22,.61,.36,1) on period change; label color .2s.
- BarPair bars — height .6s transition on mount/data change.
- Donut arcs — stroke-dasharray .7s cubic-bezier(.22,.61,.36,1) on mount/data change.
- sc-fade (.25s both) — ExportSheet scrim fade-in.
- sc-rise (.32s cubic-bezier(.22,.61,.36,1) both) — ExportSheet sheet slide/scale up (keyframe: translateY(14px) scale(.98) opacity0 -> translateY(0) scale(1) opacity1).
- Export pill / tiles / CTA — no explicit transition (instant re-skin); Chip/Progress transitions exist in theme but unused here.

## Data fields
- READ txns[] filtered by t.mode === active mode (only active profile's transactions).
- expenses = txns where amount < 0 (active mode).
- income (number) = sum of positive amounts.
- expTotal (number) = sum of -amount over expenses.
- Net saved displayed = income - expTotal via fmt(...,{cents:false}).
- byCat / segs: group expenses by t.cat summing -amount; map to {key,value,tint=CATS[cat].tint,label=CATS[cat].label,icon=CATS[cat].icon}; sort desc by value; Donut uses all segs, legend uses top 5.
- deductible (number) = sum over expenses of (-amount * t.deductible/100) when t.deductible set (% field on txn).
- gst (number) = sum of t.gst (per-txn GST amount, AUD).
- Per txn fields consumed: amount, cat, mode, deductible (%), gst. (Logbook row values $215/$45.56, '342 km/12 trips', '68 hrs', and ExportSheet figures 'FY 2025–26'/'48 images'/'$1,287.40' are HARD-CODED placeholders — not derived.)
- Formatters: fmt (AUD en-AU, optional cents/sign), fmtK ($X / $X.Xk, no decimals at >=10k). Currency AUD; GST 10% per project context.
- WRITES: none from this screen (no mutations); ExportSheet CTA is a stub. period state is local UI-only.

## Components: Card (theme.jsx primitive), IconCircle (theme.jsx primitive), Segmented (theme.jsx animated sliding control), Donut (theme.jsx SVG), BarPair (theme.jsx mini bars), Icon (theme.jsx 24-grid line icons: share, shield, receipt, car, wfh, chevR, star, sparkles, doc, film), StatPill (local sub-component in reports.jsx), ReportsScreen (screen), ExportSheet (bottom-sheet overlay), TabBar (shell.jsx, global)
## Color tokens: --cream #FBF6F0 (canvas), --paper #FFFFFF (cards), --paper-2 #F6EEE4 (segmented track), --ink #211C18, --ink-2 #6B6258, --ink-3 #A99F93, --line #ECE3D8, --line-2 #F3EBE1, --income #1F9D6B, --income-soft #DEF3E9, --accent (personal #E8602C / business #0E7C72), --accent-soft (#FDEBE0 / #DCF0ED), --accent-deep (#C2461A / #0A5950), category tints: meals #E8602C, groceries #C99A22, fuel #2F6FB0, software #7B5BD6, office #0E7C72, home #B0568F, health #D6452B, travel/income #1F9D6B, logbook row colors: car #2F6FB0 on #E2ECF6, wfh #0E7C72 on #DCF0ED, scrim rgba(20,16,12,.4), CTA/pill text #fff

**Navigation:** Entry: appears when global tab switches to 'reports' (shell key=tab+activeId remount), animated by .screen-enter (sc-fade-up .34s). Exit: switching tabs unmounts it (next screen plays its own sc-fade-up). ExportSheet entry: go('export') -> overlay mount with scrim sc-fade + sheet sc-rise; exit: onClose (scrim tap or CTA) unmounts immediately (no exit animation in prototype). Logbook rows navigate to mileage/wfh overlays which have their own back/close.
**Notes:** SwiftUI rebuild guidance: (1) Device frame 402x874; use the listed px values 1:1 as points. (2) Fonts: Schibsted Grotesk for all .num/headings (tabular-nums, tracking -0.01em), Hanken Grotesk for UI; map weights 400/500/600/700/800. Radii: card 22, inner 16, chip 12, pills 999. sh-card shadow = two layers (0 1px 2px rgba(33,28,24,.04) + 0 10px 26px -16px rgba(33,28,24,.14)) — approximate with two .shadow modifiers or a custom shadow. (3) Donut: draw with Canvas/Path arcs, rotate -90deg start, 3pt gap between segments (subtract from arc length), rounded caps, grey track ring --line; animate dash on appear (.7s). BarPair: two rounded bars per month, width 11, radius 5, animate height .6s. Segmented: matchedGeometryEffect slider, .28s spring/easeOut. (4) Period control is non-functional in the prototype — implement real Month/Quarter/FY aggregation in v1 (recompute trend, donut, deductible, GST per selected AU financial-year period). (5) Logbook row values and all ExportSheet detail figures are placeholders — wire to real mileage (km*ATA cents-per-km), WFH fixed-rate hours, receipt count, and computed deductible total. (6) Export CTA must actually generate PDF/CSV and (for 'accountant') send via the Cloudflare email service per project decisions; PDF/CSV are REAL in v1. GPS mileage auto-track is UI-only placeholder. (7) Mode/business detection: treat any profile.type !== 'personal' as business layout, using that profile's palette[0/1/2] as accent. (8) AU GST 10%, currency AUD via en-AU number formatting; replicate fmt (cents toggle, '−' minus sign U+2212) and fmtK ($X.Xk, integer k at >=10000).

---

# ProfileScreen (Profile tab). Defines: ProfileCard (sub-component), SettingRow (sub-component). Sibling overlay defined in shell.jsx: ProfilePickerSheet (bottom-sheet profile switcher — covered here as it directly relates to profile switching).

**Route:** Bottom tab "profile" (5th tab, user icon). Rendered when tab === 'profile' inside App. Reached by tapping the Profile tab in TabBar. No back button (it is a root tab screen).

**Purpose:** Account hub: shows the signed-in user identity, a dynamic multi-profile switcher grid (each profile keeps its own receipts/budgets/tax), and grouped settings rows that deep-link into Categories, Tax/GST, Connected banks, plus app-level settings (notifications, export, privacy, help) and a sign-out action. Re-skins entirely to the active profile's palette at runtime.

**Mode-aware:** Personal vs Business is expressed through the active profile's palette, which re-skins all --accent tokens at runtime (accentVars in shell): --accent = palette[0], --accent-soft = palette[1], --accent-deep = palette[2]. Personal palette p/p-soft/p-deep = #E8602C/#FDEBE0/#C2461A (terracotta); Business = #0E7C72/#DCF0ED/#0A5950 (teal). On this screen the accent drives: the identity avatar gradient + its shadow, the 'Pro' pill (accent-deep on accent-soft), the active ProfileCard gradient/border/shadow/initials/badge, the 'AI auto-categorise' row icon (sparkles tint --accent soft --accent-soft), and the tab bar active state. ProfileCard subtitle text also branches on profile.type: business shows 'Business · tap to manage', otherwise 'Everyday spending'. Each profile carries its own type ('personal'|'business') and 3-color palette; profiles beyond the first two are business with bespoke palettes (Lumen #3F5BB0/#E7EAF8/#2C4290, Rentals #2F7A55/#DFF0E6/#205B3D). NOTE: the identity block (MR / Maya Reyes / maya@studionorth.co / Pro) is hardcoded and does NOT change with the active profile in the source.

## Layout

### Scroll container
Full-height vertical scroll (.scroll: overflow-y auto, scrollbar hidden). Background inherits app-root --cream #FBF6F0. Padding 54px top / 18px sides / 124px bottom (bottom pad clears the floating tab bar). Device frame 402x874. Whole screen plays screen-enter animation on mount/profile-switch.

_Components & tokens:_ div.scroll; padding 54px 18px 124px; bg var(--cream) #FBF6F0; font-family --ui Hanken Grotesk; color --ink #211C18

### H1 title "Profile"
Top heading, flush left, no top margin.

_Components & tokens:_ h1; font-family --display Schibsted Grotesk; size 30px; weight 700; letter-spacing -0.6px; color --ink #211C18; margin 0

### Identity row
Horizontal row, marginTop 16, align center, gap 14. (1) 60x60 avatar tile, radius 20, gradient linear 135deg from --accent to --accent-deep, white tabular initials "MR", display font weight 700 size 24, shadow 0 10px 22px -10px var(--accent). (2) Flexible text column: name "Maya Reyes" 19px/700 letter-spacing -0.3px color --ink; email "maya@studionorth.co" 13.5px color --ink-3 #A99F93. (3) "Pro" pill on the right: text 11.5px/700, color --accent-deep, bg --accent-soft, padding 5px 11px, radius 999.

_Components & tokens:_ avatar 60x60 r20 gradient(--accent->--accent-deep); name 19/700; email 13.5 --ink-3 #A99F93; Pro pill --accent-deep on --accent-soft r999 pad 5/11. NOTE: name/email/MR are hardcoded literals (not bound to active profile).

### Section header "Profiles · N"
Uppercase label. Margin 22px top / 2px sides / 10px bottom. Text composes literal 'Profiles · ' + list.length. (Screenshot variant shows 'ACTIVE PROFILE' from a different build state; JSX text is authoritative.)

_Components & tokens:_ div; size 13px; weight 700; color --ink-3 #A99F93; textTransform uppercase; letter-spacing 0.3px; margin 22px 2px 10px

### Profile switcher grid (dynamic)
CSS grid, 2 columns 1fr 1fr, gap 10. One ProfileCard per profile in the `profiles` array (length = tweak profileCount, 2–4; default 3). Cards are buttons, flex:1, textAlign left, radius --r-card 22, padding 16, overflow hidden, transition all .25s. INACTIVE card: bg --paper #FFFFFF, border 1px var(--line) #ECE3D8, shadow --sh-card. ACTIVE card: bg linear-gradient(150deg, palette[0], palette[2]), border 1px palette[0], shadow 0 14px 28px -14px palette[0]; plus a decorative 80x80 circle absolutely positioned right:-20 top:-20, radius 999, bg rgba(255,255,255,.1). Card internals: 40x40 initials tile radius 12 (active: bg rgba(255,255,255,.22) text #fff / inactive: bg palette[1] soft, text palette[0]), display font 700 16px; title 15.5px/700 marginTop 12 (active #fff / inactive --ink); subtitle 12px marginTop 1 (active rgba(255,255,255,.8) / inactive --ink-3). Active card also renders an "Active" badge: inline-flex gap 4, marginTop 10, 11px/700 #fff text on rgba(255,255,255,.2), padding 3px 9px, radius 999, with a 12px check icon (sw 2.6, #fff).

_Components & tokens:_ ProfileCard grid 2col gap10; card r22 pad16; active gradient(150deg,palette0,palette2)+shadow 0 14px28px-14px palette0; initials tile 40x40 r12; subtitle text business='Business · tap to manage' else 'Everyday spending'; Active badge w/ Icon name='check' size12 sw2.6

### Add-profile button (dashed)
Full-width button, marginTop 10, padding 12, radius 14, bg --paper, border 1px DASHED --line, color --ink-2, weight 600 size 14, centered flex with gap 7, label 'Add another profile' preceded by 18px plus icon (color --ink-2). whiteSpace nowrap.

_Components & tokens:_ button r14 dashed --line #ECE3D8; --ink-2 #6B6258; Icon name='plus' size18; gap7

### Section header "Capture & tax"
Same uppercase label style as above. Margin 22px 2px 10px.

_Components & tokens:_ 13/700 --ink-3 uppercase ls0.3 margin 22/2/10

### Capture & tax Card
Card primitive: bg --paper, radius --r-card 22, shadow --sh-card, border 1px --line-2 #F3EBE1, padding overridden to '2px 16px'. Contains 4 SettingRow children. Each SettingRow: flex row align center gap 12, padding 13px 0, borderBottom 1px var(--line-2) except last. Left: IconCircle 36px (radius 13, soft bg, 19px icon at tint). Center: label flex:1, 15px/600 --ink. Right: optional detail text 13.5px/500 --ink-3 nowrap, then either a 46x28 toggle (radius 999; ON track --income #1F9D6B / OFF track --line; 22px white knob top:3 left:21(on)/3(off), shadow 0 1px 3px rgba(0,0,0,.2), transitions .2s) OR a 17px chevR chevron in --ink-3. Rows: (1) 'AI auto-categorise' icon sparkles tint --accent soft --accent-soft, toggle ON (no onClick). (2) 'Categories & rules' icon tag tint #7B5BD6 soft #EBE5F8, detail '9', onClick go('categories'). (3) 'Tax & GST settings' icon shield tint --income #1F9D6B soft --income-soft #DEF3E9, detail 'FY25–26', onClick go('tax'). (4) 'Connected banks' icon bank tint #2F6FB0 soft #E2ECF6, detail '2 linked', last (no border), onClick go('banks').

_Components & tokens:_ Card pad '2px 16px' border --line-2 #F3EBE1; SettingRow pad 13/0; IconCircle size36 isize19 r13; label 15/600; detail 13.5/500 --ink-3; toggle 46x28 knob22 --income; Icon chevR size17

### Section header "App"
Uppercase label, margin 20px 2px 10px (note: 20 top vs 22 on others).

_Components & tokens:_ 13/700 --ink-3 uppercase ls0.3 margin 20/2/10

### App Card
Same Card (pad '2px 16px'). 4 SettingRows, all use default IconCircle tint --ink-2 / soft --paper-2 #F6EEE4 (no explicit tint/soft passed): (1) 'Notifications & alerts' icon bell, toggle ON, no onClick. (2) 'Export & backup' icon download, chevron, no onClick (no handler wired). (3) 'Privacy & security' icon lock, detail 'Face ID', chevron, no onClick. (4) 'Help & support' icon info, last, chevron, no onClick.

_Components & tokens:_ IconCircle default tint --ink-2 #6B6258 soft --paper-2 #F6EEE4; icons bell/download/lock/info; detail 'Face ID'

### Sign-out button
Full-width button, marginTop 18, padding 15, radius 15, bg --paper, border 1px solid --line, text color --alert #D6452B, weight 700 size 15, centered flex gap 8, 19px logout icon in --alert + label 'Sign out'.

_Components & tokens:_ button r15 border --line bg --paper; --alert #D6452B; Icon name='logout' size19; gap8

### Footer caption
Centered text, marginTop 16: 'Snapceipt · v1.0 · Snap it. Sort it. Sorted.'

_Components & tokens:_ textAlign center; 12px; color --ink-3 #A99F93; marginTop 16

## Interactions
- **Tap a ProfileCard (any profile in grid)** -> go('profileDetail', p) -> opens ProfileDetailScreen overlay (settings-pages.jsx) for that profile, passing the full profile object as payload and isActive = (p.id === activeId). Does NOT itself switch the active profile — switching happens via the detail screen's Make Active action.
- **Tap 'Add another profile' dashed button** -> go('addProfile') -> opens AddProfileScreen overlay (addprofile.jsx). On create, App calls setMode(newType) then closes overlay.
- **Tap 'Categories & rules' row** -> go('categories') -> opens CategoriesScreen overlay.
- **Tap 'Tax & GST settings' row** -> go('tax') -> opens TaxScreen overlay.
- **Tap 'Connected banks' row** -> go('banks') -> opens ConnectedBanksScreen overlay (placeholder/UI-only per project decision).
- **Tap 'AI auto-categorise' toggle** -> Visual toggle (no onClick handler wired in source; rendered ON). In SwiftUI build, bind to a persisted setting.
- **Tap 'Notifications & alerts' toggle** -> Visual toggle (no handler wired; rendered ON).
- **Tap 'Export & backup' / 'Privacy & security' / 'Help & support' rows** -> No onClick handlers wired in source; chevron is shown but inert. Wire to real destinations in v1 (Export uses email send-to-accountant; Privacy = Face ID; Help).
- **Tap 'Sign out' button** -> No handler wired in source (purely visual). In v1, sign out of Apple/email session.
- **Tap Profile tab in TabBar** -> Navigates here (already current). Tab bar is the persistent floating nav; Snap center button opens capture overlay.
- **ProfilePickerSheet (shell overlay, route 'profilePicker'): tap a profile row** -> onSelect(id) -> setActive(id) (persists to localStorage 'sc-active') and closes sheet, re-skinning the whole app to that profile's palette.
- **ProfilePickerSheet: tap 'Add a profile'** -> onAdd -> opens addProfile overlay.
- **ProfilePickerSheet: tap scrim or backdrop** -> onClose -> dismiss sheet.

## States
- Default/populated: this screen always renders with at least one profile (profiles = ALL_PROFILES.slice(0, profileCount); profileCount 2–4). No dedicated empty state — there is always >=1 profile and identity/settings are static.
- Dynamic count: grid renders 2, 3, or 4 cards depending on profileCount tweak; 'Profiles · N' header reflects list.length. Screenshot shows 2 cards (Personal inactive + Studio North active).
- Active vs inactive card: exactly one card has active styling (gradient + Active badge) where p.id === activeId; all others are paper/inactive.
- No explicit loading or error states in this static screen. (In SwiftData/local-first build, settings detail counts like '9', 'FY25–26', '2 linked' would be live; treat as data-bound.)

## Animations
- screen-enter: applied to the screen wrapper (keyed by tab+activeId). Animation sc-fade-up .34s cubic-bezier(.22,.61,.36,1) both — from opacity 0/translateY(10px) to opacity 1/translateY(0). Re-fires whenever you enter the Profile tab OR switch active profile (key changes).
- ProfileCard transition: 'all .25s' on the card button — smooth tween when active/inactive styling changes (e.g., after switching profile and returning).
- SettingRow toggle: knob 'left' transitions .2s and track 'background' transitions .2s when toggled.
- ProfilePickerSheet (related overlay): backdrop sc-fade .25s both; sheet body sc-rise .32s cubic-bezier(.22,.61,.36,1) both (translateY(14px) scale(.98) -> settle).
- Available keyframes in design system (use as needed for derived states): sc-fade-up, sc-fade, sc-scan, sc-pop-in, sc-shimmer, sc-pulse, sc-check (stroke-dashoffset 48->0), sc-ring, sc-spin, sc-rise, sc-confetti.

## Data fields
- READ active profile: activeId (localStorage 'sc-active', default 'personal'); active = profiles.find(id===activeId)||profiles[0]; mode = active.type
- READ profiles[]: each {id, name, type ('personal'|'business'), initials, palette:[tint,soft,deep]}. profiles = ALL_PROFILES.slice(0, profileCount tweak). list.length used in 'Profiles · N' header
- READ per-profile fields used by cards: palette[0] tint, palette[1] soft, palette[2] deep, name (title), initials, type (subtitle branch)
- WRITE on profile switch (via detail Make Active / picker): setActive(id) -> setActiveId + localStorage.setItem('sc-active', id). setMode(m) finds first profile of that type and sets it active
- READ tab: localStorage 'sc-tab' (persisted on change)
- Hardcoded literals (NOT bound to profile data) on this screen: identity 'Maya Reyes' / 'maya@studionorth.co' / 'MR' / 'Pro'; settings detail strings 'AI auto-categorise' ON, Categories detail '9', Tax detail 'FY25–26', Banks detail '2 linked', Privacy detail 'Face ID', footer 'Snapceipt · v1.0 · Snap it. Sort it. Sorted.' — in the SwiftData build these counts should be derived from real data (category count, current FY, linked-bank count).

## Components: ProfileScreen (this file), ProfileCard (this file, sub-component), SettingRow (this file, sub-component), Card (theme.jsx primitive), IconCircle (theme.jsx primitive), Icon (theme.jsx, 24-grid line icons: check, plus, sparkles, tag, shield, bank, bell, download, lock, info, logout, chevR), ProfilePickerSheet (shell.jsx, related switcher overlay), TabBar (shell.jsx, persistent nav)
## Color tokens: --cream #FBF6F0 (canvas), --paper #FFFFFF, --paper-2 #F6EEE4 (default IconCircle soft for App rows), --ink #211C18, --ink-2 #6B6258 (default IconCircle tint, dashed-button text), --ink-3 #A99F93 (section labels, subtitles, detail text, chevrons, footer), --line #ECE3D8 (inactive card border, dashed border, toggle OFF track, sign-out border), --line-2 #F3EBE1 (Card border, SettingRow dividers), --income #1F9D6B (toggle ON track; Tax row tint), --income-soft #DEF3E9 (Tax row soft), --alert #D6452B (sign-out text/icon), --accent / --accent-soft / --accent-deep = active palette[0/1/2] (identity avatar gradient, Pro pill, active card, AI row icon), Personal palette #E8602C / #FDEBE0 / #C2461A, Business palette #0E7C72 / #DCF0ED / #0A5950, Categories row icon #7B5BD6 on #EBE5F8 (software/violet), Banks row icon #2F6FB0 on #E2ECF6 (fuel/blue), Active-card decorative circle rgba(255,255,255,.1); active initials tile rgba(255,255,255,.22); Active badge bg rgba(255,255,255,.2); subtitle rgba(255,255,255,.8), Toggle knob #fff with shadow 0 1px 3px rgba(0,0,0,.2)

**Navigation:** Entry: tapping the Profile tab in the persistent floating TabBar mounts ProfileScreen with screen-enter (sc-fade-up .34s). The same animation replays when activeId changes (wrapper key = tab+activeId). Exit: tapping any other tab swaps the screen (new screen-enter on the destination); tapping a row/card pushes an overlay (profileDetail, addProfile, categories, tax, banks) rendered above the tab content via absolute-positioned full-screen/sheet overlays that slide in (sc-rise) and dismiss back to this screen via their own onClose. The Snap center FAB always opens the capture overlay regardless of tab.
**Notes:** Fonts: --display = Schibsted Grotesk (tabular-nums, letter-spacing -0.01em on .num) used for H1, avatar/card initials; --ui = Hanken Grotesk for all body/UI. Radii: --r-card 22 (cards), 14/15/16 used ad-hoc on the add/sign-out buttons, 13 on IconCircle, 12 on card initials tile, 20 on avatar, 999 pills/circles. Shadows: --sh-card = 0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14); active card uses custom 0 14px 28px -14px palette0; --sh-fab is accent-tinted (tab bar Snap). SwiftUI build guidance: drop the design-only Tweaks panel and its profileCount/palette controls — instead make profiles a real SwiftData-backed list (1..n) and derive accent from the active profile. Connected banks + (elsewhere) GPS mileage are placeholder UI only. Export & backup should route to the email send-to-accountant (PDF/CSV) flow; Notifications/alerts stay in-app (no emailed reminders). Make the currently-inert rows (Export, Privacy, Help, Sign out) functional. Watch the small detail: 'Tax & GST settings' detail 'FY25–26' uses an en-dash; section header gaps are 22px top except 'App' at 20px. The screenshot's 'ACTIVE PROFILE' label and wrapped 'Add another / profile' come from a different build state — JSX text ('Profiles · N', 'Add another profile') is authoritative.

---

# AddProfileScreen — full-screen overlay with two steps: step="form" (creation form) and step="done" (success). Sub-components: TypeCard, APField, APSwitch.

**Route:** Presented as a full-screen overlay above the app (web z-index 70 for form, 78 for done). In SwiftUI: a fullScreenCover or full-bleed ZStack overlay over the Profile/Settings area. Entered via a "New profile" / add-profile action elsewhere in the app. onClose dismisses; onCreate(type, name, pal) commits the new profile and switches into it.

**Purpose:** Create a new spending profile (Personal or Business). A live-updating gradient preview card reflects every input. User picks type, enters name (+ Business: ABN and GST toggle), picks one of 8 accent gradients, then taps Create profile to reach a success step offering Switch / Done.

**Mode-aware:** Personal vs Business is the core branch of this screen. BUSINESS (default on open): TypeCard accent var(--b) teal #0E7C72 / soft #DCF0ED; shows ABN field (placeholder '12 345 678 901') + GST toggle row (default ON, income-green switch + shield IconCircle); name label 'Business name', placeholder 'e.g. Studio North'; preview subtitle 'Business profile' or 'ABN <abn>'; preview badge text 'business'; info copy 'tax categories, GST tracking and logbooks'; empty initials fallback 'BZ'; empty displayName 'New business'. PERSONAL: TypeCard accent var(--p) terracotta #E8602C / soft #FDEBE0; ABN + GST rows hidden entirely; name label 'Profile name', placeholder 'e.g. Personal'; preview subtitle 'Personal profile'; badge 'personal'; info copy 'everyday categories and budgets'; initials fallback 'ME'; empty displayName 'New profile'. NOTE: the chosen accent palette (pal) is independent of type — both types default to AP_ACCENTS[4] teal and the user can pick any of 8; the TypeCard tints (p/b) are fixed and separate from pal. The selected pal becomes the app's active accent (--accent/--accent-soft/--accent-deep) after switching into the profile.

## Layout

### FORM STEP — Root container
Full-bleed overlay, inset 0. Background var(--cream) #FBF6F0. Vertical flex column. Entry animation sc-rise .3s cubic-bezier(.22,.61,.36,1) both. Device frame 402x874.

_Components & tokens:_ background #FBF6F0; animation sc-rise (from opacity 0 translateY(14px) scale(.98) -> opacity 1 translateY(0) scale(1)) .3s cubic-bezier(.22,.61,.36,1)

### Header bar
Padding 54px top / 18px sides / 10px bottom (54px top = status-bar/notch inset). Row: space-between, center-aligned. Left: 40x40 back button. Center: title 'New profile'. Right: 40px-wide empty spacer to balance the back button (keeps title centered).

_Components & tokens:_ back button 40x40, borderRadius 12, background var(--paper) #FFFFFF, border 1px solid var(--line) #ECE3D8, centered Icon 'arrowLeft' size20 color var(--ink-2) #6B6258. Title: Hanken Grotesk (--ui), fontSize 16, fontWeight 700, color --ink #211C18, whiteSpace nowrap. Right spacer width 40.

### Scroll body
Scrollable region: flex 1, padding 4px top / 18px sides / 120px bottom (bottom pad clears the floating create bar). Class 'scroll' = hidden scrollbars. Contains: preview card, Profile type section, Details section, Accent colour section, info note.

_Components & tokens:_ padding 4px 18px 120px; scrollbar hidden (scrollbar-width none)

### Live preview card
Gradient avatar/identity card that live-updates from name/type/abn/pal. borderRadius var(--r-card) 22. padding 18. text color #fff. overflow hidden. background linear-gradient(150deg, pal[0], pal[2]). Decorative circle: absolute, right -24 top -24, 110x110, borderRadius 999, background rgba(255,255,255,.1). Inner row (relative, gap 13, center): [avatar 52x52 borderRadius 16 background rgba(255,255,255,.22), Schibsted Grotesk (--display) fontWeight 700 fontSize 20, shows apInitials] + [flex column minWidth 0: displayName fontSize 18 weight 700 letterSpacing -0.3 nowrap ellipsis; subtitle fontSize 12.5 opacity .85 marginTop 1] + [type badge: fontSize 11 weight 700 background rgba(255,255,255,.2) padding 4px10px borderRadius 999 textTransform capitalize].

_Components & tokens:_ radius 22; pad 18; gradient linear-gradient(150deg, pal[0]->pal[2]); boxShadow 0 14px 30px -16px pal[0]; transition background .3s; avatar 52 r16 bg rgba(255,255,255,.22); displayName 18/700/-0.3; subtitle 12.5/opacity.85; badge 11/700 bg rgba(255,255,255,.2) r999

### Profile type — section label
Uppercase caption above the type cards.

_Components & tokens:_ text 'Profile type'; fontSize 12.5, color --ink-3 #A99F93, fontWeight 700, margin 22px top / 2px sides / 10px bottom, textTransform uppercase, letterSpacing 0.3

### Profile type — TypeCard row
Two equal-flex TypeCards in a row, gap 10. Personal (icon 'wallet', title 'Personal', sub 'Everyday spending & budgets', tint var(--p) #E8602C, soft var(--p-soft) #FDEBE0). Business (icon 'building', title 'Business', sub 'ABN, GST & tax deductions', tint var(--b) #0E7C72, soft var(--b-soft) #DCF0ED). Default active = Business.

_Components & tokens:_ Each TypeCard: flex 1, textAlign left, borderRadius var(--r-inner) 16, padding 14, transition all .2s. ACTIVE: background=soft, border 1.5px solid tint, boxShadow none. INACTIVE: background --paper #FFFFFF, border 1.5px solid --line #ECE3D8, boxShadow --sh-card. Top row space-between: icon tile 40x40 r12 (active bg=tint else --paper-2 #F6EEE4, Icon size21 color active #fff else --ink-2 #6B6258) + radio 22x22 r999 border 2px solid (active tint else --line; active fill=tint) with check Icon size13 #fff sw2.8 when active. Title 15.5/700 marginTop 11. Sub 12/--ink-3 marginTop2 lineHeight1.3.

### Details — section label
Uppercase caption.

_Components & tokens:_ text 'Details'; 12.5/--ink-3/700; margin 22px 2px 12px; uppercase; letterSpacing 0.3

### Details — fields stack
Vertical flex column, gap 14. Field 1 (always): APField name. Label = 'Business name' if business else 'Profile name'; placeholder 'e.g. Studio North' (business) / 'e.g. Personal' (personal). If type==='business': also render APField ABN (label 'ABN', placeholder '12 345 678 901') and a GST toggle row.

_Components & tokens:_ gap 14; APField conditional label/placeholder per type

### APField primitive
Label (uppercase caption) over an input shell.

_Components & tokens:_ Label: fontSize 12.5, color --ink-3 #A99F93, fontWeight 700, marginBottom 7, uppercase, letterSpacing 0.3. Input shell: flex row align center gap 8, background --paper #FFFFFF, border 1px solid --line #ECE3D8, borderRadius 14, padding 13px 15px, boxShadow --sh-card. Optional prefix span: 15.5/600 color --ink-3. Input: borderless, transparent, flex 1, Hanken Grotesk (--ui), fontSize 15.5, fontWeight 600, color --ink #211C18.

### GST toggle row (Business only)
Row: align center, gap 12, background --paper, border 1px solid --line, borderRadius 14, padding 13px 15px, boxShadow --sh-card. Left: IconCircle 'shield' (size 36, isize 19, tint var(--income) #1F9D6B, soft var(--income-soft) #DEF3E9, internal radius 13, icon strokeWidth 1.9). Middle (flex 1): title 'Registered for GST' 14.5/700; sub 'Track GST on every receipt' 12/--ink-3 marginTop1. Right: APSwitch bound to gst (default ON).

_Components & tokens:_ IconCircle shield 36 r13, tint #1F9D6B soft #DEF3E9; title 14.5/700; sub 12/#A99F93; APSwitch

### APSwitch primitive
Toggle: 46x28 track, borderRadius 999, background var(--income) #1F9D6B when on else --line #ECE3D8, transition background .2s. Knob: absolute top 3, left 21 (on) / 3 (off), 22x22 r999 #fff, boxShadow 0 1px 3px rgba(0,0,0,.2), transition left .2s.

_Components & tokens:_ track 46x28 r999 on=#1F9D6B off=#ECE3D8; knob 22x22 #fff left 3<->21; transitions .2s

### Accent colour — section label
Uppercase caption.

_Components & tokens:_ text 'Accent colour'; 12.5/--ink-3/700; margin 22px 2px 12px; uppercase; letterSpacing 0.3

### Accent swatch picker
Flex row wrap, gap 12. 8 swatches from AP_ACCENTS. Default selected = AP_ACCENTS[4] (teal). Each swatch 44x44, borderRadius 14, background linear-gradient(150deg, p[0], p[2]). Selected (p[0]===pal[0]): boxShadow ring '0 0 0 2.5px var(--cream), 0 0 0 5px p[0]' + centered check Icon size20 #fff sw2.8. Unselected: boxShadow --sh-card. transition box-shadow .15s.

_Components & tokens:_ 8 swatches 44x44 r14 gradient 150deg p[0]->p[2]; selected ring 2.5px cream + 5px p[0] + check 20/#fff; unselected --sh-card. AP_ACCENTS: [#E8602C,#FDEBE0,#C2461A],[#DD4B39,#FBE5E1,#B5341F],[#D98A1F,#FAEEDC,#AE6A12],[#C2557A,#F7E6EE,#9C3E60],[#0E7C72,#DCF0ED,#0A5950],[#1E5E8C,#E1ECF5,#134763],[#3F5BB0,#E7EAF8,#2C4290],[#2F7A55,#DFF0E6,#205B3D]

### Info note
Tip row at bottom of scroll. marginTop 22, padding 14, borderRadius var(--r-inner) 16, background var(--paper-2) #F6EEE4. Row gap 10, align flex-start. Icon 'info' size18 color --ink-3 marginTop1. Text 12.5/--ink-2 lineHeight1.45. Copy is type-dependent: business -> "We'll set up tax categories, GST tracking and logbooks for this profile. You can change everything later."; personal -> "We'll set up everyday categories and budgets for this profile. You can change everything later."

_Components & tokens:_ r16 bg #F6EEE4 pad14; Icon info 18 #A99F93; text 12.5/#6B6258/1.45

### Create bar (floating bottom)
Absolute bottom 0, left/right 0. padding 14px top / 18px sides / 34px bottom (34px = home-indicator safe area). background linear-gradient(transparent -> var(--cream) at 28%) for a fade scrim over scrolling content. Full-width button: height 56, borderRadius 18, fontSize 17, fontWeight 700, row center gap 8 with Icon 'plus' size20 sw2.4 then 'Create profile'. VALID (name non-empty): background pal[0], color #fff, boxShadow 0 12px 24px -10px pal[0], cursor pointer. INVALID: background --line #ECE3D8, color --ink-3 #A99F93, no shadow, disabled. transition all .2s.

_Components & tokens:_ button 56h r18 17/700; valid bg pal[0] #fff shadow 0 12px 24px -10px pal[0]; invalid bg #ECE3D8 text #A99F93 disabled; scrim gradient transparent->#FBF6F0 @28%; bottom pad 34

### DONE STEP — Root container
Replaces entire screen when step==='done'. Full-bleed inset 0, z 78, background --cream #FBF6F0. Centered column (align center, justify center), padding 30.

_Components & tokens:_ background #FBF6F0; centered flex column; padding 30

### DONE — Animated avatar + ring
Wrapper 104x104 relative centered. Behind: ring div absolute inset 0, r999, background pal[0], animation sc-ring 1.1s ease-out .1s (scale .6->1.5, opacity .55->0). Front: 92x92 tile borderRadius 28, background linear-gradient(150deg, pal[0], pal[2]), color #fff, Schibsted Grotesk (--display) weight 700 fontSize 34, shows apInitials, boxShadow 0 14px 30px -10px pal[0], animation sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both.

_Components & tokens:_ ring 104 r999 pal[0] sc-ring 1.1s; tile 92 r28 gradient pal[0]->pal[2] initials 34/700 display; shadow 0 14px 30px -10px pal[0]; sc-pop-in .5s spring

### DONE — Title + body
Title 'Profile created!' fontSize 23, weight 700, Schibsted Grotesk (--display), marginTop 24, animation sc-fade-up .4s .35s both. Paragraph: fontSize 14.5, color --ink-2, center, marginTop 6, lineHeight 1.45, animation sc-fade-up .4s .45s both. Copy: "<strong color=--ink>{displayName}</strong> is ready. Switch into it any time from your profile."

_Components & tokens:_ title 23/700 display sc-fade-up @.35s; body 14.5/#6B6258/1.45 sc-fade-up @.45s; displayName bold in --ink #211C18

### DONE — Action buttons
Column gap 10, full width, marginTop 30, animation sc-fade-up .4s .55s both. Primary: 'Switch to {displayName}' height 54 borderRadius 17 background pal[0] color #fff 16/700 nowrap -> calls onCreate({type,name:displayName,pal}). Secondary: 'Done' height 54 r17 background --paper #FFFFFF border 1px solid --line #ECE3D8 color --ink 16/700 -> calls onClose.

_Components & tokens:_ primary 54h r17 bg pal[0] #fff 16/700; secondary 54h r17 bg #FFFFFF border 1px #ECE3D8 text #211C18 16/700; group sc-fade-up @.55s

## Interactions
- **Tap back button (header)** -> Calls onClose -> dismisses the whole overlay without creating a profile
- **Tap Personal TypeCard** -> setType('personal'). Re-skins details labels/placeholders, hides ABN+GST rows, changes preview subtitle to 'Personal profile', updates info-note copy, changes default initials fallback to 'ME'. Card animates active state (background->soft, border->tint, radio fills) transition all .2s
- **Tap Business TypeCard** -> setType('business'). Shows ABN field + GST toggle, preview subtitle becomes 'Business profile' (or 'ABN <abn>' once ABN entered), info-note mentions tax/GST/logbooks, default initials fallback 'BZ'. Default selected type on open
- **Type in name field** -> setName(value). Live-updates preview displayName and avatar initials (apInitials), enables Create button when trimmed length>0
- **Type in ABN field (Business)** -> setAbn(value). Live-updates preview subtitle to 'ABN <abn>' when non-empty
- **Tap GST switch (Business)** -> setGst(!gst). Knob slides left 3<->21, track recolors; default ON
- **Tap an accent swatch** -> setPal(p). Re-skins preview card gradient + shadow, selected swatch gains double-ring + check, Create button color/shadow (when valid), and done-step avatar/ring/primary button all use new palette
- **Tap Create profile (valid)** -> setStep('done') -> swaps to success step (no animation on step container itself; done-step children run their entry animations). Does NOT yet persist
- **Tap Create profile (invalid, name empty)** -> No-op; button disabled, neutral styling, cursor default
- **Tap 'Switch to {displayName}' (done step)** -> Calls onCreate({type, name: displayName, pal}) -> persists profile and switches the app's active profile into it (active accent palette re-skins app)
- **Tap 'Done' (done step)** -> Calls onClose -> dismisses overlay (profile not necessarily switched into)
- **Scroll body** -> Content scrolls under the fixed floating create bar; bottom 120px padding + gradient scrim prevent the button overlapping content

## States
- Form-empty / invalid: name is empty -> displayName falls back to 'New business' (business) or 'New profile' (personal); avatar initials fallback 'BZ'/'ME'; Create button disabled (bg --line #ECE3D8, text --ink-3, no shadow).
- Form-valid: name non-empty -> Create button active (bg pal[0], #fff, accent shadow).
- Personal type: ABN + GST rows hidden; preview subtitle 'Personal profile'; personal info copy.
- Business type (default): ABN field + GST toggle visible; subtitle 'Business profile' or 'ABN <value>'; business info copy.
- Done/success step: animated avatar (sc-pop-in), expanding ring (sc-ring), staggered fade-up of title/body/buttons; offers Switch + Done.
- No explicit loading or error state — creation is synchronous in the prototype (a real SwiftData/local-first write should keep the optimistic instant UX; surface offline-queue/sync errors via app-level toast, not this screen).

## Animations
- sc-rise (.3s cubic-bezier(.22,.61,.36,1) both) — form-step root entry: opacity 0 + translateY(14px) scale(.98) -> opacity 1 translateY(0) scale(1)
- background .3s transition — preview card gradient cross-fade when accent palette changes
- transition all .2s — TypeCard active/inactive state change and Create button valid/invalid styling
- transition box-shadow .15s — accent swatch selection ring appear/disappear
- APSwitch transitions: background .2s (track color) + left .2s (knob slide 3<->21)
- sc-ring (1.1s ease-out, .1s delay) — done step: expanding fading ring behind avatar, scale .6->1.5 opacity .55->0
- sc-pop-in (.5s cubic-bezier(.34,1.56,.64,1) both) — done step avatar tile spring scale .5->1.08->1
- sc-fade-up (.4s both, staggered delays) — done step: title @.35s, body @.45s, button group @.55s; opacity 0 translateY(10px) -> opacity 1 translateY(0)

## Data fields
- READ/WRITE step: 'form' | 'done' (local UI state, default 'form')
- READ/WRITE type: 'personal' | 'business' (default 'business')
- READ/WRITE name: String (default '') — trimmed for validity + displayName
- READ/WRITE abn: String (default '') — Business only; shown in preview subtitle
- READ/WRITE gst: Bool (default true) — Business only; 'Registered for GST'
- READ/WRITE pal: [String;3] accent palette [base, soft, deep] (default AP_ACCENTS[4] teal)
- DERIVED displayName: name.trim() || (business?'New business':'New profile')
- DERIVED valid: name.trim().length > 0
- DERIVED initials via apInitials(name,type): first letters of first two words, or first 2 chars of single word; fallback 'BZ' (business) / 'ME' (personal)
- WRITTEN on create -> onCreate({ type, name: displayName, pal }). NOTE: abn and gst are captured in form state but are NOT forwarded by onCreate in the prototype — for the SwiftData rebuild, persist type, name, accent palette (store all 3 hex or an index 0-7), abn, gst on the Profile model.
- Currency context: AUD; Business profiles enable AU GST (10%) tracking + tax-deductible % logic downstream

## Components: AddProfileScreen (overlay, two steps), TypeCard (selectable type tile with icon tile + radio check), APField (labeled input shell, optional prefix), APSwitch (46x28 pill toggle, income-green when on), IconCircle (theme.jsx primitive — used for GST shield, size 36 r13), Icon (theme.jsx line-icon, 24-grid: arrowLeft, wallet, building, check, shield, info, plus), Accent swatch grid (8 gradient buttons), Live preview identity card (gradient), Floating create bar (gradient scrim + full-width CTA), Done step: ring + spring avatar + stacked CTAs
## Color tokens: --cream #FBF6F0 (screen bg), --paper #FFFFFF (cards/fields/buttons), --paper-2 #F6EEE4 (inactive icon tile, info note bg), --ink #211C18 (primary text), --ink-2 #6B6258 (secondary text, back icon), --ink-3 #A99F93 (captions, placeholders, disabled text, info icon), --line #ECE3D8 (borders, off-switch track, disabled button bg), --line-2 #F3EBE1 (sibling line token), --p #E8602C / --p-soft #FDEBE0 / --p-deep #C2461A (Personal TypeCard tint), --b #0E7C72 / --b-soft #DCF0ED / --b-deep #0A5950 (Business TypeCard tint), --income #1F9D6B / --income-soft #DEF3E9 (GST switch on + shield IconCircle), --alert #D6452B (theme token, not used on this screen), AP_ACCENTS[8] palettes (base/soft/deep): #E8602C/#FDEBE0/#C2461A, #DD4B39/#FBE5E1/#B5341F, #D98A1F/#FAEEDC/#AE6A12, #C2557A/#F7E6EE/#9C3E60, #0E7C72/#DCF0ED/#0A5950 (default), #1E5E8C/#E1ECF5/#134763, #3F5BB0/#E7EAF8/#2C4290, #2F7A55/#DFF0E6/#205B3D, #FFFFFF (white text/knob on accents), Overlay whites on gradient: rgba(255,255,255,.22) avatar, rgba(255,255,255,.2) badge, rgba(255,255,255,.1) deco circle, --sh-card 0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14), Accent shadows: preview 0 14px 30px -16px pal[0]; create btn 0 12px 24px -10px pal[0]; done avatar 0 14px 30px -10px pal[0], --display Schibsted Grotesk (numbers/headings/initials, tabular-nums, letter-spacing -0.01em), --ui Hanken Grotesk (all UI text), Radii: --r-card 22, --r-inner 16, --r-chip 12; pills/circles 999; field/input r14; icon tile r12; IconCircle internal r13; create btn r18; done buttons r17; done avatar r28; preview avatar r16

**Navigation:** Entry: overlay mounts and plays sc-rise (.3s) covering the app (web z 70). Internal transition: Create profile -> step switches form->done (done step is z 78, children fade/pop in; the form root's sc-rise does not replay). Exit: onClose (back button, or done-step 'Done') dismisses the overlay; onCreate (done-step 'Switch to ...') commits + switches active profile then the parent dismisses. In SwiftUI use a fullScreenCover with a matching rise/scale transition; the form->done swap is an internal state change, not a navigation push.
**Notes:** Fonts: Schibsted Grotesk (--display) for the avatar initials, the done-step 'Profile created!' title, and the avatar initials in preview; everything else Hanken Grotesk (--ui). Web uses px; convert 1px->1pt for SwiftUI. The header's 54px top pad and create-bar 34px bottom pad encode notch/home-indicator safe areas — replace with safeAreaInsets in SwiftUI rather than hardcoding. apInitials logic: trim name; if empty return 'BZ'/'ME' by type; else split on whitespace, take first letter of word1 + first letter of word2 (or 2nd char of word1 if single word), uppercased. PARITY BUG TO PRESERVE-OR-FIX: onCreate only forwards {type, name, pal} — abn and gst are collected but dropped; the rebuild should persist abn+gst on the Profile model. Per project decisions: drop the design-only Tweaks panel; store accent as palette index (0-7) or 3 hex values; selected pal becomes the app-wide --accent at runtime. Creation should be local-first/optimistic (instant SwiftData write + offline mutation queue) — no spinner needed, matching the prototype's synchronous feel. Currency AUD; Business unlocks AU GST 10% + tax-deductible logic downstream. The accent swatch palette differs from the fixed Personal/Business TypeCard tints — keep both color systems separate.

---

# settings-pages.jsx defines 4 full-screen overlays: ProfileDetailScreen, CategoriesScreen ("Categories & rules"), TaxScreen ("Tax & GST settings"), ConnectedBanksScreen ("Connected banks"). Plus 4 shared local helper components: PageHeader, GroupLabel, Row, MiniSwitch. All four screens are absolutely-positioned overlays (position:absolute; inset:0; zIndex:72) on the cream canvas that slide in via sc-rise.

**Route:** Pushed/presented as full-screen overlays over the Settings/Profile tab. In SwiftUI: model each as a destination view presented via NavigationStack push or .fullScreenCover; back button (arrowLeft) calls onClose to dismiss. zIndex 72 in the web shell implies they sit above the tab bar / shell content.

**Purpose:** Settings detail pages reached from the Profile/Settings hub. ProfileDetail = per-profile hero + details + stats + manage actions. Categories & rules = smart auto-file rules + full category list with per-category receipt counts. Tax & GST = deductible/GST summary cards + business tax identity (ABN/entity/GST-registered/accounting basis) + financial-year/BAS scheduling + deduction defaults. Connected banks = PLACEHOLDER (UI-only in v1): reconcile banner, linked bank accounts with sync status + per-account auto-import toggles, connect-a-bank CTA, security note.

**Mode-aware:** Accent re-skins at runtime via var(--accent)/--accent-soft/--accent-deep = active profile palette (Personal terracotta p #E8602C / soft #FDEBE0 / deep #C2461A; Business teal b #0E7C72 / soft #DCF0ED / deep #0A5950). Affected here: Categories add (+) button bg + shadow, Smart-rules banner gradient/border/text, Tax summary 'GST on purchases' receipt icon, Tax 'Next BAS due' value color. ProfileDetailScreen is per-profile (uses profile.palette, not the active accent) and has explicit business-vs-personal branching: business adds an 'ABN' row, a 'Registered for GST' MiniSwitch row (default ON), and uses Type='Business'; stats show 41 receipts + '$1.2k Deductible YTD' (shield icon); GST state initialized to true. Personal omits ABN/GST rows, Type='Personal', stats show 7 receipts + '$301 Spent in May' (wallet icon), GST state false. TaxScreen and ConnectedBanksScreen are inherently business-oriented (ABN/BAS/deductions; business bank accounts) but render statically regardless of mode in the prototype.

## Layout

### Shared container (all 4 screens)
Root: position absolute, inset 0, zIndex 72, background var(--cream) #FBF6F0, flex column, animation sc-rise .3s cubic-bezier(.22,.61,.36,1) both. Inside: PageHeader (fixed top) then a .scroll body (flex:1, overflow-y auto, scrollbar hidden) with padding 4px 18px 40px.

_Components & tokens:_ cream #FBF6F0; r via tokens; sc-rise keyframe: from{opacity:0;translateY(14px) scale(.98)} to{opacity:1;translateY(0) scale(1)}

### PageHeader (shared)
Padding 54px 18px 12px (54 top = status-bar inset). Flex row, space-between, align center, gap 8. LEFT: back button 40x40, radius 12, background paper #FFFFFF, border 1px var(--line) #ECE3D8, centers Icon 'arrowLeft' size 20 color var(--ink-2) #6B6258. CENTER: title span fontSize 16, fontWeight 700, text-align center, flex:1, ellipsis truncation, padding 0 6px. RIGHT: trailing slot, width 40, fixed, content right-aligned.

_Components & tokens:_ paper #FFFFFF; line #ECE3D8; ink-2 #6B6258; arrowLeft path 'M19 12H5M11 6l-6 6 6 6'; back btn radius 12px

### GroupLabel (shared section header)
fontSize 12.5, color var(--ink-3) #A99F93, fontWeight 700, margin 20px 2px 10px, text-transform uppercase, letter-spacing 0.3px. Used to title each Card group.

_Components & tokens:_ ink-3 #A99F93; 12.5px/700 uppercase

### Row (shared list row)
Flex row space-between, gap 10, padding 14px 0, borderBottom 1px var(--line-2) #F3EBE1 (none if last). Label: fontSize 14.5, color var(--ink-2) #6B6258, fontWeight 500, nowrap. Value group (right): fontSize 14.5, fontWeight 700, color = valueColor or var(--ink) #211C18; optional chevR Icon size 16 color var(--ink-3). cursor pointer only when onClick set.

_Components & tokens:_ line-2 #F3EBE1; ink #211C18; ink-2 #6B6258; ink-3 #A99F93; chevR 'M9 6l6 6-6 6'

### MiniSwitch (shared toggle)
Button 46x28, radius 999, background = ON var(--income) #1F9D6B / OFF var(--line) #ECE3D8, transition background .2s. Knob: absolute top 3, left = on?21:3, 22x22 circle, background #fff, boxShadow 0 1px 3px rgba(0,0,0,.2), transition left .2s.

_Components & tokens:_ income #1F9D6B (ON); line #ECE3D8 (OFF); knob 22px #fff

### CategoriesScreen — PageHeader
Title 'Categories & rules'. Trailing = ADD button 40x40, radius 12, background var(--accent) (active profile color: p #E8602C personal / b #0E7C72 business), boxShadow 0 6px 14px -6px var(--accent), centers Icon 'plus' size 20 color #fff sw 2.3.

_Components & tokens:_ accent (re-skins); plus 'M12 5v14M5 12h14'; sw 2.3

### CategoriesScreen — Smart rules banner
Box radius var(--r-inner) 16px, padding 14, background linear-gradient(135deg, var(--accent-soft), #fff), border 1px var(--accent). Header row: Icon 'sparkles' size 18 color var(--accent) fill=true; label 'Smart rules' fontSize 13.5 fontWeight 700 color var(--accent-deep); right pill text '{RULES.length} active' (4 active) fontSize 11.5 fontWeight 700 color var(--accent-deep) marginLeft auto. Body p: margin 7px 0 0, fontSize 12.5, color var(--ink-2), lineHeight 1.4 = 'Snapceipt auto-files receipts that match these rules.'

_Components & tokens:_ r-inner 16px; accent-soft (p-soft #FDEBE0 / b-soft #DCF0ED); accent-deep (p-deep #C2461A / b-deep #0A5950); sparkles icon filled

### CategoriesScreen — Rules Card
Card marginTop 12, pad '2px 16px'. One row per RULES item (4 rows), each: flex row gap 12, padding 13px 0, borderBottom 1px var(--line-2) (none on last). LEFT: IconCircle name=cat.icon, tint=cat.tint, soft=cat.soft, size 36, isize 18 (radius 13 internal). MID column: 'If contains' fontSize 13 color var(--ink-3) fontWeight 600; below match string fontSize 14 fontWeight 700 ellipsis. RIGHT column (align end): '→ {cat.label}' fontSize 12.5 fontWeight 700 color cat.tint; optional note fontSize 11 color var(--income) #1F9D6B fontWeight 600.

_Components & tokens:_ Card: paper #FFFFFF, radius var(--r-card) 22px, shadow var(--sh-card), border 1px var(--line-2). RULES data below.

### CategoriesScreen — Categories list
GroupLabel 'Categories · {keys.length+1}' = 'Categories · 9' (8 non-income keys + 1). Card pad '2px 16px'. One row per category key (8: meals,groceries,fuel,software,office,home,health,travel): flex gap 12, padding 12px 0, borderBottom 1px var(--line-2) (none last). IconCircle (size 36 isize 18, tint/soft from CATS). Label flex:1 fontSize 14.5 fontWeight 600. Count span class 'num' fontSize 13 color var(--ink-3) fontWeight 600. Trailing Icon chevR size 16 color var(--ink-3).

_Components & tokens:_ counts: meals 12, groceries 6, fuel 9, software 7, office 4, home 3, health 2, travel 5. .num uses var(--display) Schibsted Grotesk tabular-nums -0.01em

### CategoriesScreen — New category button
Full width, marginTop 12, padding 13px, radius 14, background var(--paper), border 1px DASHED var(--line), color var(--ink-2), fontWeight 700, fontSize 14, centered flex gap 7, Icon 'plus' size 18 color var(--ink-2) + text 'New category'.

_Components & tokens:_ dashed border var(--line) #ECE3D8; radius 14px

### TaxScreen — PageHeader
Title 'Tax & GST settings'. No trailing button (empty 40px slot).

_Components & tokens:_ —

### TaxScreen — Summary cards row
Flex row gap 10. Card A (flex:1, pad 14): Icon 'shield' size 20 color var(--income) #1F9D6B; value '.num' fontSize 21 fontWeight 700 marginTop 8 = '$1,287'; caption fontSize 11.5 color var(--ink-3) fontWeight 600 = 'Deductible YTD'. Card B (flex:1, pad 14): Icon 'receipt' size 20 color var(--accent); value '$214' (.num 21/700); caption 'GST on purchases'.

_Components & tokens:_ shield path 'M12 3.5 5 6...'; income #1F9D6B; accent re-skins

### TaxScreen — Business group
GroupLabel 'Business'. Card pad '2px 16px': Row 'ABN' value '12 345 678 901'; Row 'Entity type' value 'Sole trader' chevron+onClick; inline toggle row 'Registered for GST' + MiniSwitch (state gst, default true), padding 12px 0, borderBottom 1px var(--line-2); Row 'GST accounting' value 'Cash' chevron last.

_Components & tokens:_ MiniSwitch ON=income #1F9D6B; Row tokens as shared

### TaxScreen — Financial year group
GroupLabel 'Financial year'. Card pad '2px 16px': Row 'Tax year' value 'FY 2025–26' chevron; Row 'BAS period' value 'Quarterly' chevron; Row 'Next BAS due' value '28 Jul 2026' valueColor var(--accent) (re-skins), last (no chevron).

_Components & tokens:_ valueColor var(--accent) on Next BAS due value

### TaxScreen — Deduction defaults group
GroupLabel 'Deduction defaults'. Card pad '2px 16px': Row 'Meals & entertainment' value '50%' (no chevron); Row 'Vehicle method' value 'Logbook' chevron; Row 'Home office' value '67c / hour' chevron, last.

_Components & tokens:_ —

### TaxScreen — Info note
Flex row gap 10 align flex-start, marginTop 16, padding 14, radius var(--r-inner) 16px, background var(--paper-2) #F6EEE4. Icon 'info' size 18 color var(--ink-3) marginTop 1. p margin 0 fontSize 12.5 color var(--ink-2) lineHeight 1.45 = 'These defaults pre-fill the deductible % when AI sorts a receipt. You can always override per receipt.'

_Components & tokens:_ paper-2 #F6EEE4; info icon; r-inner 16px

### ConnectedBanksScreen — PageHeader
Title 'Connected banks'. No trailing button.

_Components & tokens:_ —

### ConnectedBanks — Reconcile banner
Box radius var(--r-inner) 16px, padding 14, background var(--income-soft) #DEF3E9, flex row align center gap 11. LEFT: 38x38 square radius 12 background var(--income) #1F9D6B centering Icon 'swap' size 20 color #fff. RIGHT: title '12 receipts matched this week' fontSize 14 fontWeight 700; subtitle 'Bank lines auto-reconciled to receipts.' fontSize 12.5 color var(--ink-2) marginTop 1.

_Components & tokens:_ income-soft #DEF3E9; income #1F9D6B; swap 'M7 7h11l-3-3M17 17H6l3 3'

### ConnectedBanks — Linked accounts
GroupLabel 'Linked accounts'. Column flex gap 12. One Card (pad 16) per BANKS item (2). Top row (flex gap 12 align center): 44x44 square radius 13 background b.soft, color b.tint, font var(--display) fontWeight 700 fontSize 15, shows b.initials. Name+acct column (flex:1): name fontSize 15 fontWeight 700 ellipsis; acct fontSize 12.5 color var(--ink-3) marginTop 1. Trailing dots button (padding 6) Icon 'dots' size 20 color var(--ink-3). Divider row: marginTop 14 paddingTop 14 borderTop 1px var(--line-2). LEFT status: 7x7 dot radius 999 background var(--income) + sync text fontSize 12.5 color var(--income) fontWeight 600. RIGHT: 'Auto-import' label fontSize 12.5 color var(--ink-2) fontWeight 600 + MiniSwitch (per-bank state).

_Components & tokens:_ Bank A: CBA — Everyday, •••• 2241, initials CB, tint #E8B400, soft #FBF1CC, 'Synced 2h ago', auto true. Bank B: Amex — Business, •••• 1009, AX, tint #2F6FB0, soft #E2ECF6, 'Synced 5h ago', auto true. dots 'M5 12h.01M12 12h.01M19 12h.01'

### ConnectedBanks — Connect a bank button
Full width marginTop 12, padding 14, radius 14, background var(--paper), border 1px DASHED var(--line), color var(--ink-2), fontWeight 700 fontSize 14.5, centered flex gap 8, Icon 'plus' size 18 color var(--ink-2) + 'Connect a bank'.

_Components & tokens:_ dashed var(--line); radius 14px

### ConnectedBanks — Security note
Flex row gap 10 align flex-start, marginTop 16, padding 14, radius var(--r-inner) 16px, background var(--paper-2) #F6EEE4. Icon 'lock' size 18 color var(--ink-3) marginTop 1. p fontSize 12.5 color var(--ink-2) lineHeight 1.45 = 'Connections are read-only and bank-grade encrypted. Snapceipt can never move your money.'

_Components & tokens:_ lock 'M6.5 11V8.5a5.5 5.5 0 0 1 11 0V11...'; paper-2 #F6EEE4

### ProfileDetailScreen — PageHeader
Title 'Profile'. Trailing = edit button 40x40 radius 12 background var(--paper) border 1px var(--line), Icon 'pencil' size 18 color var(--ink-2).

_Components & tokens:_ pencil 'M4 20h4L19 9l-4-4L4 16v4ZM14 6l4 4'

### ProfileDetailScreen — Hero card
Radius var(--r-card) 22px, padding 20, color #fff, overflow hidden, background linear-gradient(150deg, pal[0], pal[2]), boxShadow 0 16px 32px -18px pal[0]. Decorative circle: absolute right -26 top -26, 120x120, radius 999, background rgba(255,255,255,.1). Header row gap 14: 56x56 radius 18 background rgba(255,255,255,.22) showing initials (var(--display) 700 22px); name fontSize 21 fontWeight 700 letterSpacing -0.4 ellipsis; subtitle '{type} profile' fontSize 13 opacity .85 capitalize. THEN if isActive: inline pill (rgba(255,255,255,.2), padding 6px 12px radius 999, fontSize 12.5/700) with Icon 'check' size 14 #fff sw 2.8 + 'Currently active'. ELSE: full-width button (marginTop 16, padding 13, radius 14, background rgba(255,255,255,.92), color pal[2], fontSize 15/700) 'Switch to this profile' (onMakeActive).

_Components & tokens:_ pal = profile.palette [accent, accent-soft, accent-deep]; check 'M5 12.5 10 17.5 19.5 7'

### ProfileDetailScreen — Details / stats / manage
GroupLabel 'Details' + Card pad '2px 16px': Row 'Profile name' value name chevron; Row 'Type' value Business/Personal; if business: Row 'ABN' value '12 345 678 901' + inline 'Registered for GST' MiniSwitch (default = biz); inline 'Accent colour' row (padding 14px 0) showing 26x26 radius 9 gradient swatch with double ring boxShadow '0 0 0 2px var(--cream), 0 0 0 4px pal[0]'. GroupLabel 'This profile' + two stat Cards (pad 14, flex:1, gap 10): #1 Icon 'receipt' color pal[0], value biz?41:7, 'Receipts'; #2 Icon biz?'shield':'wallet' color var(--income), value biz?'$1.2k':'$301', caption biz?'Deductible YTD':'Spent in May'. GroupLabel 'Manage' + Card pad '2px 16px': button 'Export this profile' (Icon download 19 var(--ink-2)) borderBottom; button 'Delete profile' (Icon trash 19 var(--alert) #D6452B, text color var(--alert)).

_Components & tokens:_ alert #D6452B; cream #FBF6F0 (ring); download 'M12 4v11M7.5 10.5...'; trash 'M5 7h14...'

## Interactions
- **Tap back button (arrowLeft) in any PageHeader** -> Calls onClose — dismisses the overlay back to the Settings/Profile hub
- **Categories: tap add (+) button in header** -> No handler wired in prototype (placeholder). Intended: create new smart rule / category
- **Categories: tap 'New category' dashed button** -> No handler wired (placeholder). Intended: open new-category creation flow
- **Categories: tap a category row (chevR shown)** -> No handler wired in prototype; chevron implies navigation to category detail/edit
- **Tax: tap Row 'Entity type' / 'GST accounting' / 'Tax year' / 'BAS period' / 'Vehicle method' / 'Home office' (chevron rows)** -> onClick set to no-op () => {} in prototype; intended to open a picker/editor for that field
- **Tax: toggle 'Registered for GST' MiniSwitch** -> setGst(!gst); flips local state (default true). Knob slides + track color animates income<->line
- **ProfileDetail: tap 'Switch to this profile' button (inactive profile only)** -> Calls onMakeActive — sets this profile active (re-skins accent palette app-wide)
- **ProfileDetail: tap edit (pencil) header button / 'Profile name' row** -> No handler wired (placeholder); intended to edit name
- **ProfileDetail: toggle 'Registered for GST' MiniSwitch (business only)** -> setGst(!gst); local state, default = biz
- **ProfileDetail: tap 'Export this profile'** -> No handler wired; intended to trigger send-to-accountant export (PDF/CSV)
- **ProfileDetail: tap 'Delete profile' (alert-colored)** -> No handler wired; intended destructive delete (should add confirm)
- **ConnectedBanks: toggle a bank's 'Auto-import' MiniSwitch** -> setAutos updates only that index: a.map((x,j)=> j===i ? !x : x). Knob slides + track color animates
- **ConnectedBanks: tap dots (overflow) button on a bank card** -> No handler wired; intended account actions menu (rename/disconnect)
- **ConnectedBanks: tap 'Connect a bank' dashed button** -> No handler wired (PLACEHOLDER feature in v1); intended bank-link flow

## States
- No explicit loading/error/empty states are coded — all four screens render static seeded data.
- Categories: 'Smart rules' banner count is data-driven (RULES.length = '4 active'); 'Categories · 9' count = 8 keys + 1. A real empty state (no rules / no categories) is not designed here.
- Categories rule note is conditional: only software ('100% deductible') and meals ('Meals · 50%') rows render the green sub-note; fuel/groceries render no note.
- Tax: 'Registered for GST' default ON (true). MiniSwitch reflects boolean; no disabled/locked state.
- ConnectedBanks: each bank shows a 'Synced Xh ago' status with a green dot (implicit success/healthy state). No error/'sync failed'/'reconnect' state designed — add for production. Auto-import default ON for both banks.
- ProfileDetail: two mutually-exclusive states in hero — isActive=true shows 'Currently active' pill (no action); isActive=false shows 'Switch to this profile' button. Business vs Personal toggles which rows/stats render (see modeAware).

## Animations
- sc-rise — entry animation for ALL four screen overlays. Trigger: mount. Keyframe: from{opacity:0; translateY(14px) scale(.98)} to{opacity:1; translateY(0) scale(1)}; duration .3s; easing cubic-bezier(.22,.61,.36,1); fill both.
- MiniSwitch knob — transition left .2s (knob slide 3px<->21px) and transition background .2s (track income<->line). Trigger: toggle tap. Used in Tax, ProfileDetail, and ConnectedBanks (per-bank).
- No other JS animations in this file. Other named system animations (sc-fade-up, sc-scan, sc-pop-in, sc-shimmer, sc-pulse, sc-check, sc-ring, sc-confetti) are NOT used on these screens.

## Data fields
- READ (Categories): CATS map (label/icon/tint/soft per key, income excluded for list), RULES [{match, cat, note?}] (4 items), counts {meals:12,groceries:6,fuel:9,software:7,office:4,home:3,health:2,travel:5}
- RULES data: {match:'Uber, DiDi, Lyft', cat:'fuel'}, {match:'Adobe, Figma, Apple', cat:'software', note:'100% deductible'}, {match:'Cafés & restaurants', cat:'meals', note:'Meals · 50%'}, {match:'Woolworths, Coles', cat:'groceries'}
- READ (Tax): Deductible YTD '$1,287', GST on purchases '$214', ABN '12 345 678 901', Entity type 'Sole trader', GST accounting 'Cash', Tax year 'FY 2025–26', BAS period 'Quarterly', Next BAS due '28 Jul 2026', Meals & entertainment '50%', Vehicle method 'Logbook', Home office '67c / hour'
- WRITE (Tax): gst boolean (Registered for GST), default true — local useState only
- READ (ConnectedBanks): BANKS [{name,acct,initials,tint,soft,sync,auto}] — CBA Everyday •••• 2241 / Amex Business •••• 1009; reconcile count '12 receipts matched this week'
- WRITE (ConnectedBanks): autos boolean[] (per-bank auto-import), seeded from BANKS[].auto (both true) — local useState only
- READ (ProfileDetail): profile {name, type, initials, palette[3]}, isActive flag; stats biz?41:7 receipts, biz?'$1.2k':'$301', ABN '12 345 678 901'
- WRITE (ProfileDetail): gst boolean (business GST toggle, default=biz); onMakeActive() switches active profile — local/state callbacks only
- NOTE: All writes are ephemeral local React state in the prototype. For SwiftUI/SwiftData: persist rules, category counts (derived), tax settings, GST-registered flag, BAS schedule, deduction defaults, and bank auto-import flags; counts derive from receipt query per category. Connected-banks data is PLACEHOLDER/mock in v1.

## Components: PageHeader (local: back btn + centered title + trailing slot), GroupLabel (local: uppercase section header), Row (local: label + value + optional chevron), MiniSwitch (local: 46x28 toggle, income/line), Card (theme: paper bg, radius 22, sh-card, 1px line-2 border), IconCircle (theme: rounded square 36, radius 13, tinted icon), Icon (theme: 24-grid line icons; used: arrowLeft, pencil, plus, sparkles[fill], chevR, shield, receipt, info, swap, dots, lock, check, download, trash, wallet + CAT icons cup/cart/fuel/film/building/home/heart/pin), Bank initials badge (44x44 radius 13 in ConnectedBanks / 56x56 radius 18 hero / 26x26 radius 9 accent swatch), Smart-rules gradient banner, Reconcile banner, Info/security note box (paper-2), Dashed-border CTA button (New category / Connect a bank)
## Color tokens: cream/canvas #FBF6F0, paper #FFFFFF, paper-2 #F6EEE4, ink #211C18, ink-2 #6B6258, ink-3 #A99F93, line #ECE3D8, line-2 #F3EBE1, income #1F9D6B, income-soft #DEF3E9, alert #D6452B, accent (Personal p #E8602C / Business b #0E7C72), accent-soft (p-soft #FDEBE0 / b-soft #DCF0ED), accent-deep (p-deep #C2461A / b-deep #0A5950), CAT meals tint #E8602C soft #FBEADF, CAT groceries #C99A22 / #F6EECE, CAT fuel #2F6FB0 / #E2ECF6, CAT software #7B5BD6 / #EBE5F8, CAT office #0E7C72 / #DCF0ED, CAT home #B0568F / #F4E4EF, CAT health #D6452B / #F8E2DD, CAT travel #1F9D6B / #DEF3E9, Bank CBA tint #E8B400 soft #FBF1CC, Bank Amex tint #2F6FB0 soft #E2ECF6, switch ON #1F9D6B / OFF #ECE3D8 / knob #fff

**Navigation:** Entry: presented as a full-screen overlay (zIndex 72) over the Settings/Profile hub; animates in with sc-rise (.3s slide-up+scale+fade). Exit: PageHeader back button (arrowLeft) calls onClose, dismissing the overlay (web has no explicit exit animation — reverse-dismiss; in SwiftUI use the matching push/pop or .fullScreenCover dismiss transition). ProfileDetail additionally exits implicitly when onMakeActive switches the active profile.
**Notes:** Fonts: --display = Schibsted Grotesk (weights 400-800) for numbers (class 'num': tabular-nums, letter-spacing -0.01em), badge initials, hero name; --ui = Hanken Grotesk (400-700) for all UI text. Radii tokens: r-card 22px, r-inner 16px, r-chip 12px; pills/circles 999; ad-hoc 14px on CTA buttons, 13px on IconCircle/bank badge, 12px on header buttons, 9px on accent swatch, 18px on hero avatar. Shadows: sh-card = 0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14); sh-pop = 0 8px 24px -8px rgba(33,28,24,.22), 0 2px 6px rgba(33,28,24,.08); sh-fab = 0 8px 20px -4px color-mix(accent 55%) , 0 3px 8px rgba(33,28,24,.18). Device 402x874. Status-bar inset baked into PageHeader top padding 54px. PROJECT CONTEXT: ConnectedBanks (and reconcile) is UI-only PLACEHOLDER in v1 — wire toggles to local state but no real bank linking. Drop the design-only Tweaks panel (separate file). Currency AUD; GST 10%; deductible-% logic real. The four chevron/onClick rows in Tax and the add/new-category/dots/connect actions are unwired placeholders to be built into real pickers/flows. Add a confirm dialog for 'Delete profile' and design missing sync-error/empty states for production. The em-dash in 'FY 2025–26' (U+2013) and bullet '·' in labels/account masks (•) are literal characters; minus sign in fmt uses U+2212 elsewhere but not on these screens.

---

# Vehicle logbook (MileageScreen) and Work from home (WFHScreen) — two full-screen overlays defined in logbook-pages.jsx. Shared sub-components: LbHeader, LbLabel, MiniStat (MiniStat is defined but UNUSED in these two screens).

**Route:** Overlays launched from shell.jsx via go('mileage') and go('wfh'); rendered as setOverlay('mileage') / setOverlay('wfh'). Entry points are HomeScreen QuickActions: car icon "Mileage" and wfh icon "WFH log" (home.jsx lines 337-338). Each renders position:absolute inset:0 zIndex:72 over the whole device. onClose => setOverlay(null) returns to whichever tab is active (Home). Settings "Vehicle method = Logbook" row exists (settings-pages.jsx:225) but is a no-op.

**Purpose:** Two PLACEHOLDER/UI-only logbook screens for AU tax deductions. (1) Vehicle logbook tracks monthly business-vehicle mileage (logbook method): km driven, claimable $, business-use %, trip count, a GPS auto-track toggle, and a recent-trips list. (2) Work-from-home log tracks FY hours at the ATO 67c/hour fixed rate: total hrs, claimable $, days logged, avg/day, a this-week bar chart, a logged-days list, and a fixed-rate explainer. Both surface a primary CTA (Add a trip / Log hours). In v1 these are UI-only; GPS auto-track is explicitly a placeholder.

**Mode-aware:** Both screens are accent-driven and re-skin at runtime. The shell injects accentVars { --accent: active.palette[0], --accent-soft: palette[1], --accent-deep: palette[2] }. PERSONAL profile -> terracotta (--p #E8602C / --p-soft #FDEBE0 / --p-deep #C2461A). BUSINESS profile -> teal (--b #0E7C72 / --b-soft #DCF0ED / --b-deep #0A5950). Everything using var(--accent)/soft/deep recolors: hero gradient + shadow, header plus button, IconCircles, business trip tint, bar fills, CTAs, the toggle's OFF? (no — toggle ON is fixed --income green, OFF is fixed --line; toggle is NOT accent-tinted). WITHIN Mileage's trip list there is also a per-row Personal vs Business distinction independent of the active profile: business trips use accent + accent-soft and a 'Business' label in accent; personal trips use --ink-3 #A99F93 on --paper-2 #F6EEE4 with a 'Personal' label in --ink-3. The hero number/stats and 67c/hour rate are static placeholders regardless of mode. Logically these logbooks are business-tax features, but the prototype does not gate them by mode.

## Layout

### LbHeader (shared)
Top bar, top-to-bottom first. Row: padding 54px top / 18px sides / 12px bottom; display flex, alignItems center, justifyContent space-between, gap 8. LEFT: back button 40x40, radius 12 (--r-chip), background --paper #FFFFFF, border 1px solid --line #ECE3D8, centered; contains Icon name='arrowLeft' size 20 color --ink-2 #6B6258. CENTER: title span fontSize 16, fontWeight 700, flex 1, textAlign center, single-line ellipsis (whiteSpace nowrap, overflow hidden, textOverflow ellipsis). Titles: 'Vehicle logbook' / 'Work from home'. RIGHT: plus button 40x40 radius 12, background = accent (passed prop, defaults var(--accent)), centered, boxShadow '0 6px 14px -6px <accent>'; contains Icon name='plus' size 20 color #fff strokeWidth(sw) 2.3. Font family UI = Hanken Grotesk.

_Components & tokens:_ LbHeader; back-btn 40x40 r12 paper #FFFFFF border --line #ECE3D8; title 16/700 ink #211C18; plus-btn 40x40 r12 bg --accent shadow 0 6px 14px -6px accent; icons arrowLeft 20 / plus 20 sw2.3 #fff

### Scroll container (shared)
className 'scroll' (overflow-y auto, no scrollbar, -webkit-overflow-scrolling touch). flex:1, padding '4px 18px 110px' (110px bottom clears the floating CTA). Background of whole overlay is --cream #FBF6F0.

_Components & tokens:_ scroll; padding 4/18/110; canvas --cream #FBF6F0

### MILEAGE — Hero card
Gradient hero. borderRadius var(--r-card)=22, padding 18, color #fff, position relative, overflow hidden, background linear-gradient(150deg, var(--accent), var(--accent-deep)), boxShadow '0 14px 30px -16px var(--accent)'. Decorative circle: absolute right -24 top -24, 120x120, borderRadius 999, background rgba(255,255,255,.1). Header row (position relative): Icon name='car' size 20 #fff; label 'This month · May' fontSize 13 fontWeight 600 opacity .9 nowrap; right-aligned pill 'Logbook method' fontSize 11.5 fontWeight 700, background rgba(255,255,255,.2), padding '4px 10px', borderRadius 999. Big number (.num, display font, tabular-nums, letter-spacing -0.01em): '342' fontSize 38 fontWeight 700 marginTop 6 lineHeight 1 + ' km' span fontSize 20 fontWeight 600 opacity .85. Stats row: display flex gap 18 marginTop 14; three groups separated by 1px vertical dividers (width 1, background rgba(255,255,255,.25)). Each group: small label fontSize 12 opacity .85 fontWeight 600 nowrap; value .num fontSize 18 fontWeight 700 marginTop 1. Values: Claimable $215.00, Business use 78%, Trips 12.

_Components & tokens:_ Hero div (not Card primitive); r-card 22; bg linear-gradient(150deg, accent, accent-deep); shadow 0 14px 30px -16px accent; numbers .num Schibsted Grotesk 38/700 + 20/600; pill rgba(255,255,255,.2) r999; divider rgba(255,255,255,.25)

### MILEAGE — GPS auto-track card
Card primitive, marginTop 14, pad 14 (pad maps to padding). Card style: background --paper #FFFFFF, borderRadius --r-card 22, boxShadow --sh-card, border 1px solid --line-2 #F3EBE1. Inner row: flex alignItems center gap 12. IconCircle name='pin' tint var(--accent) size 38 isize 19 (circle: 38x38 radius 13, background --accent-soft, Icon 19px accent sw1.9). Middle (flex 1): title 'Auto-track with GPS' 14.5/700 ink; subtitle 'Detects drives & logs them for you' 12.5 color --ink-3 #A99F93 marginTop 1. Toggle button (right, flexShrink 0): see interactions/states.

_Components & tokens:_ Card pad14 paper #FFFFFF r22 sh-card border --line-2; IconCircle pin 38/iso19 accent on accent-soft r13; toggle 46x28 r999

### MILEAGE — 'Recent trips' label
LbLabel component: fontSize 12.5, color --ink-3 #A99F93, fontWeight 700, margin '20px 2px 10px', textTransform uppercase, letterSpacing 0.3. Text 'Recent trips'.

_Components & tokens:_ LbLabel uppercase 12.5/700 ink-3 #A99F93 ls0.3 margin 20/2/10

### MILEAGE — Recent trips list
Card pad='2px 14px'. Maps over TRIPS (5 rows). Each row: flex alignItems center gap 12, padding '13px 2px', borderBottom '1px solid var(--line-2) #F3EBE1' except last row (none). LEFT: IconCircle name='car' size 40 isize 20; business trips tint var(--accent) on soft var(--accent-soft); personal trips tint --ink-3 #A99F93 on soft --paper-2 #F6EEE4. MIDDLE (flex1 minWidth0): line1 = from → to, fontSize 14 fontWeight 700, flex row gap 5, each endpoint ellipsis, with Icon name='arrowRight' size 13 color --ink-3 between them; line2 = fmtDate(date) + ' · ' + purpose, fontSize 12.5 color --ink-3 marginTop 1 nowrap. RIGHT (textAlign right, flexShrink0): km value .num fontSize 14.5 fontWeight 700 nowrap (e.g. '12.4 km'); below 'Business'/'Personal' fontSize 11 fontWeight 700, color accent if business else --ink-3.

_Components & tokens:_ Card pad 2px/14px; rows 13px/2px divider --line-2; IconCircle car 40/iso20; arrowRight 13 ink-3; km .num 14.5/700; tag 11/700 accent or ink-3

### MILEAGE — Floating CTA
absolute bottom 0 left 0 right 0, padding '14px 18px 34px', background linear-gradient(transparent, var(--cream) 28%) (fade scrim over scroll). Button: width 100%, height 54, borderRadius 17, background var(--accent), color #fff, fontSize 16 fontWeight 700, flex center gap 8, boxShadow '0 12px 24px -10px var(--accent)', nowrap. Content: Icon name='plus' size 20 #fff sw2.3 + 'Add a trip'.

_Components & tokens:_ CTA 100%x54 r17 bg accent #fff 16/700 shadow 0 12px 24px -10px accent; scrim gradient to --cream 28%; plus icon 20 sw2.3

### WFH — Hero card
Identical structure/tokens to Mileage hero. Header: Icon name='wfh' size 20 #fff; label 'This financial year' 13/600 opacity .9; right pill '67c / hour' 11.5/700 rgba(255,255,255,.2) r999. Big number '68.0' 38/700 + ' hrs' 20/600 opacity .85. Stats (gap 18, dividers rgba(255,255,255,.25)): Claimable $45.56, Days logged 11, Avg / day 6.2h. Same gradient/shadow/decorative circle as Mileage.

_Components & tokens:_ Hero same tokens as Mileage; icon wfh; pill '67c / hour'; numbers .num 38/700 + 18/700 stats

### WFH — 'This week' bar chart card
Card marginTop 14 pad 18. Header row: flex justifyContent space-between alignItems baseline; left 'This week' 14.5/700 nowrap; right '35.0 hrs' .num fontSize 13 color --ink-3 fontWeight 600. Bars container: flex alignItems flex-end gap 8 height 96 marginTop 14. WEEK=[6,7.5,8,6.5,7,0,0], DOW=['M','T','W','T','F','S','S'], maxH=8. Each bar column: flex1, column, alignItems center, gap 6; bar track width 100% maxWidth 26 height 70 alignItems flex-end; bar fill width 100%, height = max((h/8)*70, 3)px, borderRadius 7, background var(--accent) if h>0 else --line #ECE3D8, transition height .5s; day label DOW[i] fontSize 11 color --ink-3 fontWeight 600.

_Components & tokens:_ Card pad18; header 14.5/700 + .num 13/600 ink-3; bars h96, fill maxW26/h70 r7 accent or --line; transition height .5s; labels 11/600 ink-3

### WFH — 'Logged days' label
LbLabel: text 'Logged days' (same style: 12.5/700 uppercase ink-3 ls0.3 margin 20/2/10).

_Components & tokens:_ LbLabel uppercase 12.5/700 ink-3

### WFH — Logged days list
Card pad='2px 14px'. Maps WFH (5 rows). Row: flex alignItems center gap 12, padding '13px 2px', borderBottom 1px solid --line-2 except last. LEFT: IconCircle name='clock' tint var(--accent) size 40 isize 20 (background defaults --accent-soft). MIDDLE (flex1 minWidth0): line1 = fmtDate(date,{weekday:'short',day:'numeric',month:'short'}) fontSize 14.5 fontWeight 700 nowrap; line2 = note 12.5 color --ink-3 marginTop 1 ellipsis. RIGHT: hrs.toFixed(1)+' h' .num fontSize 15 fontWeight 700 flexShrink0.

_Components & tokens:_ Card pad 2px/14px; IconCircle clock 40/iso20 accent/accent-soft; date 14.5/700; note 12.5 ink-3; hrs .num 15/700

### WFH — Fixed-rate explainer
Info box: flex gap 10 alignItems flex-start marginTop 16, padding 14, borderRadius var(--r-inner)=16, background --paper-2 #F6EEE4. Icon name='info' size 18 color --ink-3 #A99F93 marginTop 1. Paragraph: margin 0, fontSize 12.5, color --ink-2 #6B6258, lineHeight 1.45: 'The 67c fixed rate covers electricity, internet, phone & stationery. No need to keep separate bills.'

_Components & tokens:_ Info box r-inner 16 bg --paper-2 #F6EEE4; info icon 18 ink-3; text 12.5 ink-2 #6B6258 lh1.45

### WFH — Floating CTA
Same as Mileage CTA (absolute, scrim gradient to --cream 28%, padding 14/18/34). Button 100%x54 r17 bg accent #fff 16/700 shadow 0 12px 24px -10px accent. Content: Icon plus 20 #fff sw2.3 + 'Log hours'.

_Components & tokens:_ CTA 100%x54 r17 accent; label 'Log hours'; plus 20 sw2.3

## Interactions
- **Tap header back button (arrowLeft, both screens)** -> Calls onClose -> setOverlay(null); overlay unmounts and returns to Home (the active tab).
- **Tap header plus button (top-right, both screens)** -> No-op in prototype (no onClick). REBUILD: open the add/log sheet (same action as bottom CTA).
- **Tap GPS auto-track toggle (Mileage only)** -> setAuto(!auto). Toggles local boolean state `auto` (initial true). ON: track background var(--income) #1F9D6B, knob slides left:21; OFF: track background --line #ECE3D8, knob left:3. Animated via CSS transition background .2s and left .2s. PLACEHOLDER — no real GPS.
- **Tap 'Add a trip' CTA (Mileage)** -> No handler in prototype. REBUILD: present add-trip form (from/to/purpose/km/date/business toggle).
- **Tap 'Log hours' CTA (WFH)** -> No handler in prototype. REBUILD: present log-hours form (date/hours/note).
- **Tap a trip row / logged-day row** -> No handler in prototype (rows are non-interactive divs). Optionally add edit/detail in rebuild.
- **Scroll the body** -> Native scroll; bottom CTA stays fixed over a cream fade scrim. Hidden scrollbar.

## States
- MILEAGE empty: no empty-state implemented — TRIPS is hardcoded (5 items). REBUILD should add an empty state (e.g. EmptyArt + 'No trips yet') when trips list is empty.
- WFH empty: no empty-state implemented — WFH/WEEK hardcoded. Bars with h===0 (Sat/Sun) already render as a 3px min-height stub in --line color (the built-in 'no hours' visual). REBUILD add empty list state.
- Loading: none in prototype (static seed data). REBUILD: SwiftData-backed lists render instantly (local-first); no spinner needed.
- Success: GPS toggle visually reflects on/off immediately. No save/confirmation toasts implemented.
- Error: none handled in prototype.
- Toggle states (Mileage): auto=true (income-green track, knob right) vs auto=false (line-gray track, knob left).
- Bar states (WFH): h>0 -> accent fill scaled to (h/8)*70px; h===0 -> 3px --line stub.

## Animations
- sc-rise — overlay entrance for BOTH screens. Duration .3s, easing cubic-bezier(.22,.61,.36,1), fill both. Keyframes: from {opacity:0; transform:translateY(14px) scale(.98)} to {opacity:1; transform:translateY(0) scale(1)}. Trigger: screen mount.
- GPS toggle transitions (Mileage) — track `transition: background .2s`; knob `transition: left .2s`. Trigger: tap toggle.
- Bar height transition (WFH) — bar fill `transition: height .5s`. Trigger: render/value change (bars grow from baseline).
- screen-enter (shell wrapper) — sc-fade-up .34s cubic-bezier(.22,.61,.36,1) applies to the underlying tab content, not the overlay itself.
- Note: sc-card shadow, sc-scan/sc-pop-in/sc-shimmer/sc-pulse/sc-check/sc-ring/sc-confetti are defined globally but NOT used in these two screens.

## Data fields
- MILEAGE hero (hardcoded placeholders): month label 'May', total km 342, Claimable $215.00, Business use 78%, Trips 12, badge 'Logbook method'.
- MILEAGE GPS toggle: local boolean `auto` (default true) — UI-only, not persisted.
- TRIPS[] (read): { from:String, to:String, purpose:String, km:Number, date:ISO 'YYYY-MM-DD', biz:Bool }. 5 seed rows. Sorted newest-first as authored.
- WFH hero (hardcoded placeholders): 'This financial year', total hrs 68.0, badge '67c / hour', Claimable $45.56, Days logged 11, Avg / day 6.2h.
- WFH WEEK[] (read): [6,7.5,8,6.5,7,0,0] hours Mon-Sun; DOW labels ['M','T','W','T','F','S','S']; maxH=8 (chart scale); week total label '35.0 hrs'.
- WFH[] (read): { date:ISO, hrs:Number, note:String }. 5 seed rows.
- Formatters: fmtDate(iso) default {day:'numeric',month:'short'} for trips; fmtDate(iso,{weekday:'short',day:'numeric',month:'short'}) for WFH rows; locale en-AU. hrs.toFixed(1)+' h'. Currency is AUD (literal strings here, but fmt() helper in theme.jsx formats en-AU 2dp $).
- REBUILD WRITES (none in prototype): add-trip form -> Trip{from,to,purpose,km,date,isBusiness}; log-hours -> WfhDay{date,hours,note}. Derived: claimable km = ATO cents/km method OR logbook% (placeholder uses logbook method, $215/342km); WFH claimable = totalHrs * $0.67.

## Components: LbHeader (back btn 40x40 r12, centered title 16/700, accent plus btn 40x40 r12), LbLabel (uppercase section label 12.5/700 ink-3), MiniStat (DEFINED but UNUSED in these two screens — Card pad14 with .num 21/700 value + 11.5/600 label), Card (theme.jsx: paper #FFFFFF, r-card 22, sh-card, border 1px --line-2, default pad 16), IconCircle (theme.jsx: size x size box, borderRadius 13, soft bg, Icon sw1.9), Icon (theme.jsx: 24-grid line icons; used: arrowLeft, plus, car, pin, arrowRight, wfh, clock, info), Custom gradient Hero (inline, NOT a primitive), Custom GPS toggle switch (inline 46x28 r999), Custom this-week bar chart (inline; NOT the BarPair primitive), Floating CTA button + cream fade scrim (inline)
## Color tokens: --cream #FBF6F0 (overlay canvas + CTA scrim target), --paper #FFFFFF (Card bg, back btn bg), --paper-2 #F6EEE4 (personal-trip IconCircle soft, WFH info box bg), --ink #211C18 (titles, primary numbers), --ink-2 #6B6258 (back arrow color, info paragraph), --ink-3 #A99F93 (subtitles, labels, dividers text, personal trip tint/tag, info icon, empty bar fill via --line), --line #ECE3D8 (back btn border, toggle OFF track, zero-height bar fill), --line-2 #F3EBE1 (Card border, row dividers), --accent (active palette[0]; --p #E8602C personal / --b #0E7C72 business) — hero gradient start, plus btn, IconCircles, business tint, bar fills, CTAs, --accent-soft (palette[1]; #FDEBE0 / #DCF0ED) — IconCircle backgrounds, --accent-deep (palette[2]; #C2461A / #0A5950) — hero gradient end, --income #1F9D6B (GPS toggle ON track) / --income-soft #DEF3E9, #FFFFFF / #fff (hero text, knob, CTA text, header plus icon), rgba(255,255,255,.1) hero decorative circle; rgba(255,255,255,.2) hero pill; rgba(255,255,255,.25) hero dividers; rgba(255,255,255,.85/.9) opacity hero subtext, rgba(0,0,0,.2) toggle knob shadow

**Navigation:** ENTER: mounted overlay animates in with `animation: sc-rise .3s cubic-bezier(.22,.61,.36,1) both` (keyframes: from opacity 0, translateY(14px) scale(.98) -> to opacity 1, translateY(0) scale(1)). No explicit exit animation — the overlay unmounts immediately on close (React conditional render; in SwiftUI use a matching reverse transition or .transition(.move/.opacity)). Back button (LbHeader arrowLeft) and the header plus button: back calls onClose; the header plus button currently has NO onClick handler (dead button in prototype). Bottom CTA buttons (Add a trip / Log hours) also have no handlers in the prototype — wire them to a add/log sheet in the rebuild.
**Notes:** Fonts: --display = Schibsted Grotesk (weights 400-800 loaded; used at 700/600 for numbers + the .num class which adds font-variant-numeric: tabular-nums + letter-spacing -0.01em). --ui = Hanken Grotesk (weights 400-700; all UI text/labels/buttons). Apply .num to every numeric value (hero totals, stats, km, hrs, week total). Radii: --r-card 22, --r-inner 16, --r-chip 12, pills/circles 999; note the CTA uses radius 17 and IconCircle uses 13 (NOT a token — hardcoded). Shadows: --sh-card = '0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14)'; hero shadow '0 14px 30px -16px var(--accent)'; CTA shadow '0 12px 24px -10px var(--accent)'; header plus '0 6px 14px -6px <accent>'; toggle knob '0 1px 3px rgba(0,0,0,.2)'. Device 402x874 (scaled to fit, max 1.18x). z-index 72 for both overlays. The header plus button and both bottom CTAs are dead in the prototype — implement their actions in the rebuild. The this-week chart and the GPS toggle are bespoke inline widgets, NOT the BarPair/Segmented primitives. Per project decisions: GPS auto-track is PLACEHOLDER (UI only); WFH 67c rate is the fixed ATO rate; currency AUD. Drop the Tweaks panel (icon stroke-width re-skinning via .icons-bold/.icons-thin classes won't apply). Build WFH/mileage data on SwiftData (local-first) with last-write-wins sync.

---

# CreateQuoteScreen (two states in one file: 1. Quote editor / "New quote" full-screen overlay; 2. "Quote sent!" success overlay). Source: /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/quote-page.jsx

**Route:** Mounted as overlay key 'quote' in shell.jsx (line 212): {overlay === 'quote' && <CreateQuoteScreen onClose={() => setOverlay(null)} />}. Triggered by go('quote') from the Home screen "Create Quote" QuickAction (home.jsx line 328), which renders ONLY when mode === 'business'. SwiftUI equivalent: a fullScreenCover presented from the Business Home, with a single onClose dismiss callback. Editor container z-index 72; success container z-index 78 (sits above editor).

**Purpose:** Business-only flow to compose and send a client quote: pick a bill-to client, edit/add/remove line items, toggle AU GST (10%), watch the live subtotal/GST/total recompute, then send (email) the quote. On send, a celebratory success state confirms the quote number, amount, and recipient. Quote SN-0042 is a fixed placeholder; the file holds 3 seed line items for Northwind Studio. Accent re-skins to teal (Business) because the entry point only exists in Business mode.

**Mode-aware:** This screen is BUSINESS-ONLY. Its sole entry point (Home 'Create Quote' QuickAction) renders only when mode==='business' (home.jsx). There is no Personal variant of the quote flow. It reads the active-profile accent via var(--accent)/var(--accent-soft); because reached only in Business, accent resolves to teal: --accent #0E7C72, --accent-soft #DCF0ED, --accent-deep #0A5950. (If somehow opened in Personal it would terracotta-skin #E8602C / #FDEBE0 / #C2461A, but that path is unreachable.) Other Business profiles (Lumen #3F5BB0.., Rentals #2F7A55..) re-skin accent per their palette[0/1/2] at runtime. The GST toggle and success check are fixed income-green #1F9D6B regardless of profile (not accent-tinted).

## Layout

### Container / canvas (editor)
Full-bleed absolute overlay filling the 402x874 device (position:absolute, inset:0). Vertical flex column. Entry animation sc-rise. The screen has 3 vertical zones: fixed header, scrollable body, and a pinned bottom action bar overlapping the scroll content.

_Components & tokens:_ background var(--cream) #FBF6F0; display:flex; flexDirection:column; animation sc-rise .3s cubic-bezier(.22,.61,.36,1) both; zIndex 72; font-family var(--ui) Hanken Grotesk; text color var(--ink) #211C18

### Header bar
Top row: left close button (X), centered title 'New quote', right-aligned quote number badge 'SN-0042'. Title is flex:1 centered; right slot is a fixed 40px-wide container right-justifying its text so the title stays optically centered. Large top padding accounts for the iOS status bar / notch.

_Components & tokens:_ row padding 54px top / 18px sides / 12px bottom; display:flex; alignItems:center; justifyContent:space-between; gap 8. Close button: 40x40, radius 12 (var(--r-chip)), background var(--paper) #FFFFFF, border 1px solid var(--line) #ECE3D8, centered, flexShrink:0, contains Icon name='close' size 20 color var(--ink-2) #6B6258. Title: fontSize 16, fontWeight 700, flex:1, textAlign center, whiteSpace nowrap (ink #211C18, Hanken). Quote badge 'SN-0042': fontSize 12.5, fontWeight 700, color var(--ink-3) #A99F93, nowrap, inside a 40px-wide flex container justifyContent flex-end, flexShrink:0

### Scroll body
Scrollable region (class 'scroll' = overflow-y auto, hidden scrollbars, -webkit-overflow-scrolling touch). Contains top-to-bottom: 'BILL TO' label, client Card, 'LINE ITEMS' header row with Add button, line-items Card, totals Card, info note. Bottom padding 120px keeps content clear of the pinned action bar.

_Components & tokens:_ flex:1; padding 4px top / 18px sides / 120px bottom

### 'Bill to' section label
Uppercase eyebrow label above the client card.

_Components & tokens:_ text 'Bill to'; fontSize 12.5; color var(--ink-3) #A99F93; fontWeight 700; margin 4px top, 2px sides, 8px bottom; textTransform uppercase; letterSpacing 0.3px

### Bill-to client Card
Card primitive (pad=14). Row: 42x42 monogram tile 'NW' in accent-soft, then name+email stacked (flex:1, minWidth:0 for truncation), then a right chevron indicating it's tappable to change the client. Static placeholder: Northwind Studio / accounts@northwind.co.

_Components & tokens:_ Card: background var(--paper) #FFFFFF, borderRadius var(--r-card) 22, boxShadow var(--sh-card) (0 1px 2px rgba(33,28,24,.04),0 10px 26px -16px rgba(33,28,24,.14)), border 1px solid var(--line-2) #F3EBE1, padding 14. Inner row: display flex, alignItems center, gap 12. Monogram: 42x42, radius 13, background var(--accent-soft) (Business=#DCF0ED), color var(--accent) (Business=#0E7C72), fontFamily var(--display) Schibsted Grotesk, fontWeight 700, fontSize 15, text 'NW'. Name: fontSize 15, fontWeight 700, ink #211C18. Email: fontSize 12.5, color var(--ink-3) #A99F93, marginTop 1. Icon name='chevR' size 17 color var(--ink-3) #A99F93

### 'Line items' header row
Row above the items card: left uppercase label 'Line items', right 'Add' button (plus icon + text) in accent color that appends a new line item.

_Components & tokens:_ row margin 20px top / 2px sides / 8px bottom; display flex; alignItems center; justifyContent space-between. Label 'Line items': fontSize 12.5, color var(--ink-3) #A99F93, fontWeight 700, uppercase, letterSpacing 0.3, nowrap. Add button: fontSize 13, color var(--accent) (Business #0E7C72), fontWeight 700, flex row, gap 3, with Icon name='plus' size 15 color var(--accent) strokeWidth(sw) 2.3 then ' Add'

### Line items Card
Card with pad='2px 14px' (2px vertical, 14px horizontal). Maps over items array; each row: description + 'qty × unitPrice' subtitle (flex:1, truncating desc), the line amount (qty×price) right-aligned in tabular display font, and an X remove button. Every row except the last has a bottom hairline divider. Seed items: 'Brand identity — discovery' 1×$1,200; 'Logo & visual system' 1×$3,400; 'Brand guidelines document' 1×$900.

_Components & tokens:_ Card tokens as above (radius 22, sh-card, border var(--line-2)), padding '2px 14px'. Row: display flex, alignItems center, gap 10, padding '13px 0', borderBottom 1px solid var(--line-2) #F3EBE1 (none on last row). Desc: fontSize 14.5, fontWeight 600, single-line truncate (nowrap+ellipsis). Subtitle '{qty} × {fmt(price,no-cents)}': fontSize 12.5, color var(--ink-3) #A99F93, marginTop 1. Line amount (class 'num' = Schibsted Grotesk tabular-nums letterSpacing -0.01em): fontSize 14.5, fontWeight 700, nowrap, shown as fmt(qty*price, no cents). Remove button: padding 4, flexShrink 0, Icon name='close' size 16 color var(--ink-3) #A99F93

### Totals Card
Card with style marginTop 14, pad='2px 16px'. Three rows: Subtotal (with divider), GST (10%) row with amount + toggle (with divider), Total row (no divider, larger, accent-colored). Subtotal/GST show full cents via fmt(); total uses fmt() with cents.

_Components & tokens:_ Card tokens as above, marginTop 14, padding '2px 16px'. Subtotal row: flex space-between, padding '13px 0', borderBottom 1px solid var(--line-2). Label fontSize 14 color var(--ink-2) #6B6258; value class 'num' fontSize 14 fontWeight 700 ink. GST row: flex alignItems center space-between, padding '11px 0', borderBottom 1px solid var(--line-2). Label 'GST (10%)' fontSize 14 color var(--ink-2) nowrap; right cluster gap 10 with amount (class 'num' fontSize 14 fontWeight 700, color var(--ink) #211C18 when on else var(--ink-3) #A99F93) and the toggle. Total row: flex space-between alignItems center, padding '14px 0'. Label 'Total' fontSize 15.5 fontWeight 700 ink; value class 'num' fontSize 22 fontWeight 700 color var(--accent) (Business #0E7C72)

### GST toggle (switch)
Custom pill switch in the GST row. Track 42x26 radius 999; knob 20x20 white circle that slides left↔right. On = income green track, knob at right; Off = neutral line track, knob at left.

_Components & tokens:_ Track: width 42, height 26, borderRadius 999, background var(--income) #1F9D6B when on else var(--line) #ECE3D8, position relative, transition background .2s. Knob: absolute top 3, left 19 (on) / 3 (off), 20x20, radius 999, background #fff, transition left .2s, boxShadow 0 1px 3px rgba(0,0,0,.2)

### Info note
Disclaimer block below totals: info icon + paragraph about validity and conversion. Non-interactive.

_Components & tokens:_ container display flex, gap 10, alignItems flex-start, marginTop 16, padding 14, borderRadius var(--r-inner) 16, background var(--paper-2) #F6EEE4. Icon name='info' size 18 color var(--ink-3) #A99F93 marginTop 1. Paragraph fontSize 12.5, color var(--ink-2) #6B6258, lineHeight 1.45, text 'Valid for 14 days. Accepted quotes convert straight into an invoice.'

### Bottom action bar (pinned)
Absolutely positioned at the bottom spanning full width, overlaying the scroll with a transparent-to-cream gradient so content scrolls underneath. Two buttons: a square secondary 'doc' button (preview/PDF, non-wired) and the primary full-width 'Send quote' button with share icon. Large bottom padding for the home indicator.

_Components & tokens:_ bar position absolute, bottom 0, left/right 0, padding '14px 18px 34px', background linear-gradient(transparent, var(--cream) #FBF6F0 28%), display flex, gap 10. Secondary button: 56x56, borderRadius 18, background var(--paper) #FFFFFF, border 1px solid var(--line) #ECE3D8, centered, flexShrink 0, Icon name='doc' size 22 color var(--ink-2) #6B6258. Primary 'Send quote' button: flex:1, height 56, borderRadius 18, background var(--accent) (Business #0E7C72), color #fff, fontSize 17, fontWeight 700, flex row center, gap 8, boxShadow '0 12px 24px -10px var(--accent)' (accent-tinted, akin to sh-fab), nowrap; contains Icon name='share' size 20 color #fff then ' Send quote'

### SUCCESS STATE container
Replaces the entire screen when done===true. Centered column: animated success ring + check badge, 'Quote sent!' heading, descriptive paragraph naming quote number/amount/recipient, full-width 'Done' button that calls onClose.

_Components & tokens:_ container position absolute inset 0, zIndex 78, background var(--cream) #FBF6F0, flex column, alignItems center, justifyContent center, padding 30

### SUCCESS: ring + check badge
104x104 stage holding two layered circles. Behind: a full circle that scales up and fades (expanding ring). Front: a 92x92 rounded square (radius 28) in income green with a drop shadow, containing a 50px white checkmark SVG that draws itself.

_Components & tokens:_ stage 104x104 relative flex center. Ring layer: absolute inset 0, borderRadius 999, background var(--income) #1F9D6B, animation sc-ring 1.1s ease-out .1s. Badge: 92x92, borderRadius 28, background var(--income) #1F9D6B, flex center, animation sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both, boxShadow '0 14px 30px -10px var(--income)'. Check SVG 50x50, path stroke #fff strokeWidth 2.8 round caps/joins, strokeDasharray 48, animation sc-check .5s .35s ease-out both

### SUCCESS: heading + paragraph
Heading 'Quote sent!' then a paragraph: 'Quote SN-0042 for {total} was emailed to Northwind Studio.' with quote number and total bolded in ink. Total here uses fmt(total,{cents:false}) (no cents).

_Components & tokens:_ Heading: fontSize 23, fontWeight 700, fontFamily var(--display) Schibsted Grotesk, marginTop 24, animation sc-fade-up .4s .35s both. Paragraph: fontSize 14.5, color var(--ink-2) #6B6258, textAlign center, marginTop 6, lineHeight 1.45, animation sc-fade-up .4s .45s both; embedded <strong> spans color var(--ink) #211C18

### SUCCESS: Done button
Full-width primary button dismissing the overlay (onClose).

_Components & tokens:_ marginTop 28, width 100%, height 54, borderRadius 17, background var(--accent) (Business #0E7C72), color #fff, fontSize 16, fontWeight 700, animation sc-fade-up .4s .55s both

## Interactions
- **Tap header close button (X)** -> Calls onClose -> shell sets overlay=null, dismissing the quote overlay back to Business Home. No confirmation; edits are discarded (in-memory only).
- **Tap bill-to client Card (chevron affords it)** -> No handler wired in prototype (Card has no onClick). In rebuild this should open a client picker. Currently inert.
- **Tap 'Add' button (line-items header)** -> addItem(): appends { desc:'New line item', qty:1, price:0 } to items. New row renders at bottom of items Card; subtotal/GST/total recompute live. Adds $0.00 to subtotal.
- **Tap a line item row's X button** -> removeItem(i): filters out item at index i. Row disappears, dividers recompute (new last row loses its divider), totals recompute live. No undo. Can remove down to zero items (subtotal becomes $0.00).
- **Tap GST toggle** -> setGstOn(!gstOn): flips boolean. Track color animates green<->neutral over .2s, knob slides over .2s. GST amount switches between subtotal*0.1 and $0.00 and its color switches ink<->ink-3; Total recomputes live.
- **Tap secondary 'doc' button (bottom bar)** -> No handler wired (intended: preview/PDF). Inert in prototype.
- **Tap 'Send quote' button** -> setDone(true): swaps the entire screen for the success state (success ring/check/heading/paragraph/Done all animate in). In rebuild this is where the quote is persisted and emailed to the client.
- **Tap 'Done' (success state)** -> Calls onClose -> dismisses overlay back to Business Home.
- **Scroll body** -> Vertical scroll of the content region; bottom action bar stays pinned and content fades under its gradient. No scroll-linked animations.

## States
- Default/populated (editor): 3 seed line items, GST on, live totals. Subtotal = $5,500.00, GST(10%) = $550.00, Total = $6,050.00.
- GST off: GST row shows $0.00 in muted ink-3, toggle track neutral grey, Total = subtotal only ($5,500.00).
- Empty line items (all removed via X): items Card renders no rows (collapses to its 2px vertical padding, effectively a thin empty card); Subtotal/GST/Total all $0.00. No dedicated empty illustration; prototype does not guard against zero items. Rebuild should add an empty-state hint and disable Send.
- Newly added item: 'New line item', qty 1, price $0 (adds a $0.00 row); needs an editor in rebuild (prototype rows are not individually editable).
- Success: full-screen confirmation with animated check, 'Quote sent!', and a summary line naming SN-0042 + total + Northwind Studio.
- No loading state and no error state are modeled; send is instant and synchronous. Rebuild must add a sending/in-flight state on the Send button and an error/retry path for the email API.
- No editing of description/qty/price is implemented in the prototype (text is display-only); rebuild needs inline editors or a per-item detail sheet.

## Animations
- sc-rise (editor entry): from { opacity:0; translateY(14px) scale(.98) } to settled; .3s cubic-bezier(.22,.61,.36,1) both. Trigger: editor overlay mounts.
- sc-ring (success): expanding fading ring behind badge; scale .6->1.5, opacity .55->0; 1.1s ease-out, delay .1s. Trigger: done becomes true.
- sc-pop-in (success badge): scale .5->1.08->1 with opacity fade-in; .5s cubic-bezier(.34,1.56,.64,1) both. Trigger: done becomes true.
- sc-check (success checkmark): strokeDashoffset 48->0 drawing the tick; .5s, delay .35s, ease-out both. Trigger: done becomes true.
- sc-fade-up (success text/button): opacity 0->1 + translateY(10px)->0; .4s each, staggered delays heading .35s, paragraph .45s, Done button .55s, both. Trigger: done becomes true.
- GST toggle transitions (CSS transition, not keyframe): track background .2s and knob left .2s. Trigger: tapping the GST toggle.
- Value recompute (no transition): Subtotal/GST/Total update instantly on any items or gstOn change.

## Data fields
- READS (seed/placeholder, all in-memory): items[] = [{desc, qty, price}] (QUOTE_ITEMS: 'Brand identity — discovery'/1/1200, 'Logo & visual system'/1/3400, 'Brand guidelines document'/1/900); gstOn (bool, default true); done (bool, default false). Client hardcoded: name 'Northwind Studio', email 'accounts@northwind.co', monogram 'NW'. Quote number hardcoded 'SN-0042'.
- COMPUTED: subtotal = Σ(qty*price); gst = gstOn ? subtotal*0.1 : 0; total = subtotal + gst. Currency AUD via fmt() (en-AU, '$' prefix, '−' minus glyph). Line amounts/subtitles use fmt(...,{cents:false}); Subtotal/GST/Total use fmt() with cents; success paragraph uses fmt(total,{cents:false}).
- WRITES (rebuild, since prototype only mutates local state): on Send -> persist Quote {number, clientId, lineItems[], gstApplied, subtotal, gstAmount, total, validForDays:14, status} to SwiftData; enqueue offline mutation; email the quote PDF/summary to the client via the email service (send-to-client export). Accepted quotes 'convert straight into an invoice' (model a quote->invoice conversion path). GST is AU 10%.
- Per project rules: Currency AUD, AU GST 10%; emailed quote uses the same email service that powers send-to-accountant exports (NOT a reminder). No emailed reminders.

## Components: CreateQuoteScreen (this file's exported component; props: onClose), Card (theme.jsx primitive: bg paper, radius 22, sh-card, 1px line-2 border; pad prop accepts number or CSS string), Icon (theme.jsx; 24-grid line icons; used: close, chevR, plus, info, doc, share, check via inline SVG), fmt (theme.jsx AUD formatter; options {sign,cents}), Custom GST switch (inline, not a shared primitive), Success ring/check badge (inline SVG + layered circles, not a shared primitive), Bottom action bar (inline; secondary doc button + primary Send button), Class 'num' (Schibsted Grotesk tabular-nums, letterSpacing -0.01em) applied to all monetary figures
## Color tokens: --cream #FBF6F0 (screen + success bg, bottom-bar gradient target), --paper #FFFFFF (cards, close/doc/secondary buttons), --paper-2 #F6EEE4 (info note bg), --ink #211C18 (primary text, active GST amount), --ink-2 #6B6258 (close icon, doc icon, subtotal/GST labels, success paragraph), --ink-3 #A99F93 (eyebrow labels, SN-0042 badge, chevron, item subtitle, remove X, info icon, inactive GST amount), --line #ECE3D8 (button borders, GST track when off), --line-2 #F3EBE1 (card borders, row dividers), --accent (Business #0E7C72 teal): client monogram fg, Add button, Total value, Send button bg + its tinted shadow, Done button bg, --accent-soft (Business #DCF0ED): client monogram tile bg, --income #1F9D6B: GST toggle track when on, success ring + badge + its shadow, #FFFFFF: knob, Send/Done button text, success check stroke, shadows: --sh-card 0 1px 2px rgba(33,28,24,.04),0 10px 26px -16px rgba(33,28,24,.14) (cards); Send button '0 12px 24px -10px var(--accent)'; success badge '0 14px 30px -10px var(--income)'; toggle knob '0 1px 3px rgba(0,0,0,.2)'

**Navigation:** Entry: presented as full-screen overlay 'quote' via go('quote') from the Business Home 'Create Quote' QuickAction; appears with sc-rise (.3s cubic-bezier(.22,.61,.36,1)) translateY(14px)+scale(.98)->settle. Exit: header X (any time) or success Done -> onClose -> overlay dismissed back to Home (prototype has no slide-out exit animation; SwiftUI fullScreenCover default dismiss is acceptable). The success view is an in-place swap (not a navigation push); editor->success has no transition wrapper, individual elements animate via sc-ring/sc-pop-in/sc-check/sc-fade-up.
**Notes:** Fonts: var(--display)=Schibsted Grotesk (weights 400-800; used for monogram, all monetary 'num' figures, success heading; tabular-nums + letterSpacing -0.01em). var(--ui)=Hanken Grotesk (weights 400-700; all other UI text). Radii: card 22 (--r-card), inner 16 (--r-inner, info note), chip 12 (--r-chip, close button); buttons use bespoke 17/18; toggle/knob/circles 999. Device frame 402x874. Implementation gaps to close in rebuild: (1) line items are NOT editable in the prototype (desc/qty/price are static text) - add inline editing or a per-line detail sheet; (2) bill-to Card and bottom 'doc' button are inert - wire client picker + PDF preview; (3) no loading/error states on Send - add in-flight + failure/retry for the email API; (4) no guard against zero line items - consider disabling Send and showing a hint. Per project decisions: emailing the quote uses the same Cloudflare email service as send-to-accountant exports (PDF/CSV), local-first write to SwiftData + offline queue, AUD currency, AU GST 10%. Drop the design-only Tweaks panel. fmt() uses a real minus glyph U+2212 for negatives (quotes are positive here). File defines exactly two screens/states (editor + success), both covered. Key files: /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/quote-page.jsx (screen), /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/theme.jsx (Card, Icon, fmt, tokens), /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/snapceipt.html (CSS variables + keyframes), /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/shell.jsx (overlay mount, accent re-skin), /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/home.jsx (business-only entry).

---

# AddManualScreen (full-screen modal overlay, zIndex 72) — "Add manually". Contains two visual states in one component: (1) the entry/edit form, (2) the success confirmation overlay (zIndex 78) rendered when `done === true`.

**Route:** Presented as overlay `manual` from shell.jsx (route 'manual' -> setOverlay('manual')). Mounted as `<AddManualScreen mode={mode} onClose={() => setOverlay(null)} onSave={onSave} />`. `mode` = active profile type ('personal' | 'business'). `onSave(tx)` prepends the new tx to the global list with id 'n'+Date.now(). `onClose` dismisses the overlay (sets overlay to null). Entry trigger from UI not in this file (a "+/Add manually" affordance elsewhere routes to 'manual').

**Purpose:** Let the user add a transaction by hand without using the camera/OCR. Pick Expense vs Income (accent shifts to green for income), enter an amount via a custom on-screen keypad (amount-first big total), pick a category chip (own brand color per category), type a merchant/source, confirm the date (read-only Today), then Save (enabled only once an amount > 0 is entered) which writes the transaction and shows an animated success screen.

**Mode-aware:** Personal vs Business differs ONLY in accent color, applied at runtime via CSS vars set on app-root from the active profile's palette (--accent = palette[0], --accent-soft = palette[1], --accent-deep = palette[2]). Personal = terracotta #E8602C, Business = teal #0E7C72 (and other business profiles, e.g. Lumen #3F5BB0, Rentals #2F7A55, define their own palettes). This accent re-skins: the amount number color (when entered), the Save button bg+shadow, and the success badge/ring/Done button — but ONLY in Expense mode. In Income mode the tint is ALWAYS income green #1F9D6B regardless of profile. The success subline shows the mode name capitalized ('saved to Personal'/'Business'). Category chips always use their own fixed brand colors (mode-independent). Layout, copy ('Add manually'), keypad, and card are identical across modes. mode is also written into the saved tx.

## Layout

### Root container
Full-bleed overlay covering device (402x874). position absolute, inset 0, zIndex 72, vertical flex column. Enter animation sc-rise .3s cubic-bezier(.22,.61,.36,1) both.

_Components & tokens:_ background var(--cream) #FBF6F0; display flex column; animation sc-rise .3s

### Header
Fixed top bar. Padding 54px top / 18px sides / 8px bottom. Three-part row (close button, centered title, spacer) with gap 8, justify space-between, align center.

_Components & tokens:_ Close button: 40x40, radius 12 (--r-chip), background var(--paper) #FFFFFF, border 1px solid var(--line) #ECE3D8, centered; contains Icon name='close' size 20 color var(--ink-2) #6B6258. Title: 'Add manually' fontSize 16, fontWeight 700, flex 1, textAlign center, whiteSpace nowrap, color var(--ink) #211C18, font --ui Hanken Grotesk. Right spacer: width 40 (balances close button).

### Body wrapper
Scrollless flex column, padding 0 18px, flex 1, minHeight 0. Holds toggle, amount, chips, card, spacer, keypad.

_Components & tokens:_ padding 0 18px; flex 1; display flex column; minHeight 0

### Type toggle (Segmented)
Animated sliding segmented control, 2 options Expense | Income. Sliding thumb translates on selection. tint prop = active accent color (green for income).

_Components & tokens:_ Segmented primitive: container background var(--paper-2) #F6EEE4, radius 999, padding 4, grid 2 equal cols. Thumb: absolute top4/bottom4/left4, width calc((100%-8px)/2), background var(--paper) #FFFFFF, radius 999, shadow 0 2px 6px -2px rgba(33,28,24,.18), transition transform .28s cubic-bezier(.22,.61,.36,1), translateX(idx*100%). Labels: fontSize 14, weight 600, letterSpacing -0.1; selected color var(--ink) #211C18, unselected var(--ink-3) #A99F93, color transition .2s. NOTE: tint prop is passed but Segmented does not visually consume it for the thumb (thumb stays paper white) — tint flows to amount/chips/save instead.

### Amount display
Centered amount-first big total. Padding 22px top / 14px bottom. Small uppercase label 'AMOUNT' above the big number.

_Components & tokens:_ Label: fontSize 12.5, color var(--ink-3) #A99F93, weight 700, uppercase, letterSpacing 0.4. Number: class 'num' (font --display Schibsted Grotesk, tabular-nums, letterSpacing -0.01em base) overridden to fontSize 52, weight 700, letterSpacing -1, lineHeight 1, marginTop 4. Color = tint (accent or income green #1F9D6B) when cents>0, else var(--ink-3) #A99F93. Value = fmt(cents/100) -> AUD e.g. '$0.00','$12.50' (en-AU, always 2 decimals, '$' prefix, '−' minus for negatives but amount here is non-negative).

### Category chip picker
Horizontal scroll row of pill chips, gap 8, overflowX auto, paddingBottom 4. Expense mode shows all CATS except 'income' (8 chips: meals, groceries, fuel, software, office, home, health, travel). Income mode shows only the single 'income' chip (and chips are disabled). Each chip uses that category's own brand colors.

_Components & tokens:_ Chip: flex 0 0 auto, flex-row align center gap 7, padding 8px 13px, radius 999, fontSize 13, weight 700, whiteSpace nowrap. Selected (on): background = category.soft, color = category.tint, border 1px solid category.tint. Unselected: background var(--paper) #FFFFFF, color var(--ink-2) #6B6258, border 1px solid var(--line) #ECE3D8. Leading Icon: size 15, color = category.tint when on else var(--ink-3) #A99F93; income chip icon uses fill=true (arrowDown filled). Category tints/softs: meals cup #E8602C/#FBEADF, groceries cart #C99A22/#F6EECE, fuel fuel #2F6FB0/#E2ECF6, software film #7B5BD6/#EBE5F8, office building #0E7C72/#DCF0ED, home home #B0568F/#F4E4EF, health heart #D6452B/#F8E2DD, travel pin #1F9D6B/#DEF3E9, income arrowDown #1F9D6B/#DEF3E9.

### Merchant + Date card
Card with two stacked rows. marginTop 12, pad '2px 14px'. Row 1: text input for merchant/source with leading icon, bottom border divider. Row 2: date row (read-only 'Today') with leading calendar icon and trailing chevron.

_Components & tokens:_ Card primitive: background var(--paper) #FFFFFF, radius var(--r-card) 22px, shadow var(--sh-card) (0 1px 2px rgba(33,28,24,.04),0 10px 26px -16px rgba(33,28,24,.14)), border 1px solid var(--line-2) #F3EBE1. Row1: padding 12px 0, gap 10, borderBottom 1px solid var(--line-2) #F3EBE1; leading Icon = 'tag' (expense) or 'wallet' (income) size 19 color var(--ink-3) #A99F93; input flex 1, no border/outline, transparent bg, font --ui, fontSize 15, weight 600, color var(--ink) #211C18, placeholder 'Merchant (e.g. Officeworks)' (expense) / 'Source (e.g. Invoice #1043)' (income). Row2: padding 12px 0, gap 10; Icon 'calendar' size 19 color var(--ink-3); text 'Today · 30 May 2026' flex 1 fontSize 15 weight 600 color var(--ink); trailing Icon 'chevR' size 16 color var(--ink-3) #A99F93. Date is STATIC/read-only in this prototype (chevron implies a picker, not implemented).

### Flex spacer
Empty flex:1 minHeight:8 element pushing keypad to bottom of body, above the Save bar.

_Components & tokens:_ flex 1; minHeight 8

### Custom keypad
4-row numeric pad. Rows: [1 2 3],[4 5 6],[7 8 9],[00 0 backspace]. Column gap 8, row gap 8.

_Components & tokens:_ Key button (digits, 00, 0): flex 1, height 56, radius 16 (--r-inner), background var(--paper) #FFFFFF, border 1px solid var(--line) #ECE3D8, shadow var(--sh-card), font --display Schibsted Grotesk, fontSize 24, weight 600, color var(--ink) #211C18, centered. Backspace key: same box (flex1 h56 r16 paper border line shadow) containing Icon name='close' size 22 color var(--ink-2) #6B6258 (X glyph reused as delete).

### Save bar
Bottom action area, padding 12px top / 18px sides / 30px bottom. Single full-width Save button. Label 'Save expense' or 'Save income'. Disabled until amount entered.

_Components & tokens:_ Button: width 100%, height 56, radius 18, fontSize 17, weight 700, flex-row center gap 8, whiteSpace nowrap, transition all .2s. Enabled (cents>0): background = tint (accent or income green), color #fff, shadow '0 12px 24px -10px '+tint (accent-tinted glow), leading Icon 'check' size 20 color #fff sw 2.6. Disabled (cents==0): background var(--line) #ECE3D8, color var(--ink-3) #A99F93, no shadow, check icon color var(--ink-3).

### SUCCESS overlay (done state)
Replaces entire screen when done=true. Centered column: animated ring + check badge, headline, amount/destination line, Done button. zIndex 78, padding 30, centered both axes, background var(--cream) #FBF6F0.

_Components & tokens:_ Badge wrapper 104x104 relative centered. Pulsing ring: absolute inset0, radius 999, background = tint, animation sc-ring 1.1s ease-out .1s (scale .6->1.5, opacity .55->0). Check badge: 92x92, radius 28, background = tint, shadow '0 14px 30px -10px '+tint, animation sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both; contains SVG check (50x50, path stroke #fff width 2.8, strokeDasharray 48, animation sc-check .5s .35s ease-out both). Headline: '{Income|Expense} added!' fontSize 23 weight 700 font --display, marginTop 24, animation sc-fade-up .4s .35s both. Subline: fontSize 14.5 color var(--ink-2) #6B6258 textAlign center marginTop 6 lineHeight 1.45 animation sc-fade-up .4s .45s both; contains bold amount fmt(amount) class 'num' color var(--ink) #211C18 + 'saved to' + bold capitalized mode color var(--ink). Done button: marginTop 28, width 100%, height 54, radius 17, background = tint, color #fff, fontSize 16 weight 700, animation sc-fade-up .4s .55s both; onClick = onClose.

## Interactions
- **Tap close (X) button in header** -> Calls onClose() -> overlay unmounts, returns to underlying tab screen. No save.
- **Tap 'Expense' or 'Income' segment in Segmented** -> setKind(value). Switches isInc; thumb slides (transform .28s); accent tint recomputes (income -> #1F9D6B green, else profile accent). Category set swaps (all-but-income vs income-only), activeCat forced to 'income' in income mode, chips become disabled, merchant icon/placeholder swap (tag/Merchant vs wallet/Source). Amount number & Save button re-tint.
- **Tap a digit key (1-9, 0)** -> press(d): setCents(v => min(v*10 + d, 9999999)). Appends digit to cents (amount in cents, so display is /100). Capped at 9,999,999 cents ($99,999.99).
- **Tap '00' key** -> dbl(): setCents(v => min(v*100, 9999999)). Appends two zeros (shift left by 2 decimal places), capped.
- **Tap backspace key (X-glyph bottom-right)** -> back(): setCents(v => floor(v/10)). Removes last digit.
- **Tap a category chip (expense mode)** -> setCat(k). Selects category; chip re-skins to its soft bg + tint border/text/icon. Disabled (no-op) in income mode.
- **Type in merchant/source input** -> setMerchant(e.target.value). Free text. On save, trimmed; empty falls back to 'Income' (income) or the category label (expense).
- **Tap date row** -> No handler wired — purely visual (chevron suggests future date picker). Date is hardcoded 'Today · 30 May 2026' / ISO '2026-05-30'.
- **Tap Save button (when cents>0)** -> save(): builds tx object and calls onSave(tx), then setDone(true) -> success overlay animates in. Save is disabled (no-op) when cents==0.
- **Tap Done on success overlay** -> Calls onClose() -> overlay unmounts.

## States
- Empty / initial: kind='expense', cents=0, cat='meals', merchant='', done=false. Amount shows '$0.00' in muted ink-3. Save disabled (line bg, ink-3 text, no shadow). Category 'meals' selected by default.
- Editing/active: cents>0. Amount number takes accent/income tint. Save button enabled (tint bg, white text, accent-tinted shadow).
- Income mode: tint = income green #1F9D6B; only the single 'income' chip shown and chips disabled; merchant placeholder 'Source (e.g. Invoice #1043)', icon 'wallet'; Save label 'Save income'.
- Success: done=true renders the confirmation overlay (ring + pop-in check + staggered fade-up text + Done). Terminal state for this component (no return-to-form).
- No loading or error states exist in the prototype — save is synchronous and always succeeds locally. (For SwiftUI/SwiftData: write is local-first/instant; no error UI in original. If adding async sync, add error handling not present here.)

## Animations
- sc-rise .3s cubic-bezier(.22,.61,.36,1) both — triggered on form overlay mount (slides up 14px + scale .98->1, fade in).
- Segmented thumb: transition transform .28s cubic-bezier(.22,.61,.36,1) — triggered on Expense/Income toggle (sliding pill).
- Segmented label color transition .2s — on selection change.
- Save button transition all .2s — color/background/shadow change when amount crosses 0 (enable/disable).
- sc-ring 1.1s ease-out .1s — success: expanding fading pulse ring behind check badge (scale .6->1.5, opacity .55->0).
- sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both — success: check badge springs in (scale .5->1.08->1, fade).
- sc-check .5s .35s ease-out both — success: checkmark stroke draws in (strokeDashoffset 48->0).
- sc-fade-up .4s .35s both — success headline rises+fades.
- sc-fade-up .4s .45s both — success subline rises+fades.
- sc-fade-up .4s .55s both — success Done button rises+fades (staggered .35/.45/.55s).

## Data fields
- READ: mode (prop, 'personal'|'business') — drives accent palette + success destination text.
- READ: CATS map — category labels/icons/tint/soft.
- STATE: kind ('expense'|'income'), cents (integer cents, amount = cents/100), cat (category key, expense only), merchant (string), done (bool).
- WRITTEN via onSave(tx): merchant = merchant.trim() || (isInc ? 'Income' : category.label); cat = activeCat ('income' when income, else selected cat); amount = isInc ? +amount : -amount (expenses stored NEGATIVE, income POSITIVE); date = '2026-05-30' (hardcoded ISO); mode = prop mode; ai = false; method = 'Manual entry'; gst = isInc ? undefined : +(amount - amount/1.1).toFixed(2) (AU GST 10% extracted from gross, income has no GST).
- shell.jsx onSave adds id = 'n'+Date.now() and prepends to txns list.
- NOTE other SEED tx fields not set here: tax, deductible, note, logbook — absent on manual entries (undefined).

## Components: Segmented (animated sliding control, theme.jsx) — Expense/Income toggle, Card (theme.jsx) — merchant + date container, Icon (theme.jsx, 24-grid line icons sw default 1.85) — close, tag, wallet, calendar, chevR, check, plus category icons cup/cart/fuel/film/building/home/heart/pin/arrowDown, Key (local sub-component in manual-page.jsx) — keypad digit button, Custom category chip (inline button, NOT the shared Chip primitive — re-implemented to use per-category soft/tint colors), fmt() (theme.jsx) — AUD currency formatter (en-AU, 2dp, '$' prefix, '−' for negatives), CATS (theme.jsx) — category metadata map (label/icon/tint/soft), Success badge + ring + drawn check (inline SVG/divs in manual-page.jsx)
## Color tokens: cream/canvas #FBF6F0, paper #FFFFFF, paper-2 #F6EEE4, ink #211C18, ink-2 #6B6258, ink-3 #A99F93, line #ECE3D8, line-2 #F3EBE1, accent (personal p) #E8602C, accent-soft (p-soft) #FDEBE0, accent-deep (p-deep) #C2461A, accent (business b) #0E7C72, accent-soft (b-soft) #DCF0ED, accent-deep (b-deep) #0A5950, income #1F9D6B, income-soft #DEF3E9, alert #D6452B, cat meals #E8602C/#FBEADF, cat groceries #C99A22/#F6EECE, cat fuel #2F6FB0/#E2ECF6, cat software #7B5BD6/#EBE5F8, cat office #0E7C72/#DCF0ED, cat home #B0568F/#F4E4EF, cat health #D6452B/#F8E2DD, cat travel #1F9D6B/#DEF3E9, cat income #1F9D6B/#DEF3E9, shadow sh-card 0 1px 2px rgba(33,28,24,.04),0 10px 26px -16px rgba(33,28,24,.14), success badge shadow 0 14px 30px -10px <tint>, save shadow 0 12px 24px -10px <tint>, segmented thumb shadow 0 2px 6px -2px rgba(33,28,24,.18), check stroke #fff, tint = income #1F9D6B if income else var(--accent) (re-skins per active profile palette[0])

**Navigation:** Entry: overlay mounts with animation `sc-rise .3s cubic-bezier(.22,.61,.36,1) both` (container slides up 14px + scales 0.98->1, fades in). Exit: close button (top-left X) or, on success screen, the "Done" button both call `onClose()` which unmounts the overlay (no explicit exit animation in JSX — instant unmount; SwiftUI should mirror with a dismiss transition). Saving transitions in-place to the success overlay (no navigation, same component re-renders with `done=true`). There is NO back-to-form path once saved; only Done -> close.
**Notes:** Source: /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/manual-page.jsx (full). Primitives/tokens resolved from /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/theme.jsx and CSS vars/keyframes in /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/snapceipt.html. Wiring/navigation from /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/shell.jsx (overlay 'manual', lines 176/213; onSave line 185; accentVars line 187). Device frame 402x874.

SwiftUI rebuild notes: (1) cents-as-integer keypad model maps cleanly to an Int and computed Decimal/100; cap at 9,999,999 cents. Format with NumberFormatter currency en_AU (AUD). Use Schibsted Grotesk (display, tabular figures, tracking ~ -0.01em; amount overrides to -1px tracking at 52pt) and Hanken Grotesk (UI). (2) Date is currently a static read-only row — to make REAL per project decisions, wire a DatePicker behind the chevron (default Today); original hardcodes 2026-05-30. (3) Expenses stored as NEGATIVE amounts, income POSITIVE; GST = gross - gross/1.1 (AU 10%, income exempt) — keep this convention for SwiftData model + tax-deductible % logic. (4) Save is local-first instant write in original (no loading/error). For real app, persist to SwiftData immediately + enqueue offline mutation; success overlay can show right away. (5) The Segmented 'tint' prop is passed but the shared control keeps a white thumb — accent only appears via amount/chips/save/success, so a faithful rebuild keeps the toggle thumb neutral. (6) Backspace reuses the 'close' (X) glyph as the delete icon. (7) Category chip here is a bespoke per-category-colored pill, NOT the shared Chip primitive (which fills solid accent when active) — replicate the soft-bg + tint-border style. (8) No camera/OCR on this screen — it is the manual fallback path distinct from ReceiptScanner/CaptureFlow. (9) Drop the design-only Tweaks panel per project decisions; profile palettes still drive --accent.

---

# Loyalty wallet (LoyaltyScreen), Add a card (AddLoyaltyScreen + success state), Full-screen card detail (LoyaltyCardDetail)

**Route:** Presented as full-screen overlays above the app shell (z-index layering in source: LoyaltyScreen z72, AddLoyaltyScreen z73 / success z79, LoyaltyCardDetail z74). In SwiftUI: present as full-screen covers (.fullScreenCover) stacked from a Loyalty entry point. Device frame 402x874pt.

**Purpose:** Loyalty/rewards card wallet: list branded loyalty cards (each with brand gradient, points pill, mini barcode, member number); add new cards via scan / brand picker / manual number entry with a success confirmation; open a single card full-screen in an immersive branded view with a large high-contrast scannable barcode plus Share/Done. Barcodes are REAL in v1 (generate actual scannable Code-128/EAN from the stored member number).

**Mode-aware:** Personal vs Business affects ONLY the active accent palette (--accent / --accent-soft / --accent-deep re-skin at runtime). PERSONAL accent = terracotta #E8602C (soft #FDEBE0, deep #C2461A); BUSINESS accent = teal #0E7C72 (soft #DCF0ED, deep #0A5950). This recolors: the top-right + button (and its shadow), the 'Add a card' uses ink-2 (not accent), the Scan-CTA icon tile, the selected brand chip default? no — brand chip uses brand color; the enabled 'Add to wallet' CTA + its shadow, the sparkles icons (hint + brightness note), and the success 'Done' button. The success badge/ring/check use --income (not accent) so they are mode-independent. LoyaltyCardDetail uses the CARD's own brand colors (c1/c2/c2), so it is NOT affected by Personal/Business mode. No other layout/content differences between modes.

## Layout

### LoyaltyScreen — Top app bar
Full-screen container: position absolute inset 0, background var(--cream) #FBF6F0, flex column. Header row padding 54px top / 18px sides / 12px bottom, flex space-between, gap 8, align center. LEFT: back button 40x40, radius 12, background var(--paper) #FFFFFF, 1px solid var(--line) #ECE3D8, centered Icon arrowLeft size 20 color var(--ink-2) #6B6258, flexShrink 0. CENTER: title 'Loyalty cards' fontSize 16 weight 700, flex 1, text-align center, nowrap. RIGHT: add button 40x40, radius 12, background var(--accent) (Personal #E8602C / Business #0E7C72), shadow 0 6px 14px -6px var(--accent), Icon plus size 20 color #fff strokeWidth 2.3, flexShrink 0.

_Components & tokens:_ IconCircle-like square buttons r12; title 16/700 --ui; accent FAB-square r12 sh 0 6px 14px -6px accent

### LoyaltyScreen — Scroll body
Scroll container flex 1, padding 4px top / 18px sides / 40px bottom. Intro paragraph: fontSize 13.5, color var(--ink-2) #6B6258, margin 0 2px 14px, line-height 1.45, text: 'Tap a card to show its barcode at the checkout — no more digging through your wallet.'

_Components & tokens:_ body copy 13.5 ink-2, lh1.45

### LoyaltyScreen — Card list
Vertical flex column, gap 12. Renders CARDS array (4 seed cards) as LoyaltyCard buttons. LoyaltyCard: full-width block button, text-align left, no border, radius 18, padding 16, color #fff, position relative, overflow hidden, background linear-gradient(145deg, c1, c2), boxShadow 0 12px 26px -14px c1 (card-color tinted). Decorative circle: absolute right -28 top -28, 110x110, radius 999, background rgba(255,255,255,.08). Header row (relative): LEFT column — brand name fontSize 17 weight 700 font-family var(--display) Schibsted Grotesk letter-spacing -0.2; sub fontSize 12 opacity .8 marginTop 1 nowrap. RIGHT — points pill: fontSize 11.5 weight 700, background rgba(255,255,255,.2), padding 4px 10px, radius 999, nowrap. Mini barcode: marginTop 16, height 40, radius 8, background #fff, padding 7px 12px, flex center; inner bar fill flex 1 height 100% with repeating-linear-gradient(90deg,#111 0 1.5px,transparent 1.5px 3px,#111 3px 5px,transparent 5px 8px,#111 8px 10px,transparent 10px 13px) — REPLACE with REAL barcode in v1. Member number: marginTop 8 fontSize 12.5 opacity .9 tabular-nums letter-spacing 1, relative.

_Components & tokens:_ LoyaltyCard r18 pad16 grad145(c1,c2) sh 0 12px 26px -14px c1; brand 17/700 display ls-0.2; pts pill 11.5/700 white20 r999; barcode strip h40 r8 white; num 12.5 tabular ls1

### LoyaltyScreen — Add-a-card dashed button
Below list, marginTop 14, full-width, padding 14, radius 14, background var(--paper) #FFFFFF, 1px DASHED border var(--line) #ECE3D8, color var(--ink-2), weight 700, fontSize 14.5, flex center gap 8, nowrap. Content: Icon plus size 18 color var(--ink-2) + text 'Add a card'.

_Components & tokens:_ dashed CTA r14 paper, line dashed, 14.5/700 ink-2

### LoyaltyScreen — Auto-match hint card
marginTop 16, flex row gap 10 align flex-start, padding 14, radius var(--r-inner) 16, background var(--paper-2) #F6EEE4. Icon sparkles size 18 color var(--accent) FILLED marginTop 1; paragraph fontSize 12.5 color var(--ink-2) line-height 1.45: "We'll match loyalty points to your receipts automatically when you scan."

_Components & tokens:_ hint card r16 paper-2; sparkles accent fill; 12.5 ink-2 lh1.45

### AddLoyaltyScreen — Top app bar
Container absolute inset0, background var(--cream), flex column, animation sc-rise. Header padding 54/18/12, flex space-between align center gap 8. LEFT: back button 40x40 r12 paper, 1px solid line, Icon arrowLeft size20 ink-2. CENTER: title 'Add a card' 16/700 flex1 center nowrap. RIGHT: empty spacer div width 40 flexShrink 0 (no action) to balance the back button.

_Components & tokens:_ same header pattern; right spacer 40px

### AddLoyaltyScreen — Scan CTA
Scroll body padding 4/18/120 (extra bottom for sticky footer). First element: full-width button radius var(--r-card) 22, padding 16px 18px, flex row align center gap 14, background var(--ink) #211C18 (DARK), boxShadow var(--sh-card), text-align left. LEFT icon tile 46x46 r14 background var(--accent), Icon scan size24 #fff. MIDDLE: title 'Scan card barcode' #fff 15.5/700; sub 'Point at the back of any loyalty card' rgba(255,255,255,.6) 12.5 marginTop1. RIGHT: Icon chevR size18 rgba(255,255,255,.5). Tapping launches camera barcode scanner (VisionKit / Vision barcode detection in v1).

_Components & tokens:_ dark CTA r22 ink bg; accent tile 46 r14; scan icon; chevR white50

### AddLoyaltyScreen — Search field
marginTop 14, flex row align center gap 9, background var(--paper), 1px solid var(--line), radius 14, padding 11px 14px, boxShadow var(--sh-card). Icon search size19 color var(--ink-3) #A99F93 + text input placeholder 'Search 300+ brands', no border/outline, transparent bg, flex1, font-family var(--ui) Hanken Grotesk, fontSize 15, color var(--ink) #211C18.

_Components & tokens:_ search field r14 paper, search icon ink-3, input 15 ui

### AddLoyaltyScreen — Brand grid
Section label 'Popular in Australia' fontSize 12.5 color var(--ink-3) weight 700 margin 20px 2px 10px, UPPERCASE, letter-spacing 0.3. Grid: 3 columns (1fr 1fr 1fr), gap 10. BRANDS array = 9 tiles {name, initials i, color c}: Everyday Rewards/ER/#1A8A3C, flybuys/fb/#1457C7, MYER one/M/#111111, Sister Club/SC/#D8467F, Qantas FF/Q/#E40000, Velocity/V/#7A1FA2, Kmart/K/#E51937, BWS/B/#0A7D3E, T2 Tea/T2/#1A1A1A. Tile button: radius 16, padding 14px 8px, background var(--paper), border 1.5px solid (selected: brand color c, else var(--line)), boxShadow (selected: 0 8px 18px -10px c, else var(--sh-card)), flex column center gap 8, transition all .18s. Inner: 44x44 r13 background brand color c, centered initials #fff font-family var(--display) weight700 fontSize15. Label below: fontSize 11.5 weight 600 color var(--ink-2) center line-height 1.15.

_Components & tokens:_ brand tile r16 paper, 1.5px border (sel=brandColor) sh on-select; 44 r13 color chip display 15/700; label 11.5/600 ink-2

### AddLoyaltyScreen — Number field (conditional)
Rendered only when a brand is selected (sel != null), wrapper animation sc-fade-up .3s both. Label '{brand} number' 12.5 ink-3 700 margin 20px 2px 8px UPPERCASE ls0.3. Field: flex row align center gap 10, background var(--paper), 1px solid var(--line), radius 14, padding 13px 15px, boxShadow var(--sh-card). LEFT mini chip 30x30 r9 background sel.c, centered initials #fff display 700 12, flexShrink0. Input: value=num, onChange updates num, placeholder 'Enter card number', inputMode numeric, flex1 no border/outline transparent, font-family var(--ui) fontSize15 weight600 color var(--ink).

_Components & tokens:_ number field r14 paper; 30 r9 brand chip; numeric input 15/600 ui

### AddLoyaltyScreen — Sticky footer CTA
Absolute bottom 0 left/right 0, padding 14px 18px 34px, background linear-gradient(transparent, var(--cream) 28%) (fade scrim over content). Button: full-width height 56, radius 18, fontSize 17 weight 700, flex center gap 8, nowrap. DISABLED when !sel: background var(--line) #ECE3D8, color var(--ink-3) #A99F93, no shadow. ENABLED when sel: background var(--accent), color #fff, boxShadow 0 12px 24px -10px var(--accent). transition all .2s. Content: Icon plus size20 (color #fff when enabled else ink-3, sw2.3) + 'Add to wallet'. onClick -> setDone(true).

_Components & tokens:_ sticky CTA h56 r18; gradient scrim cream@28%; enabled=accent sh 0 12px 24px -10px accent

### AddLoyaltyScreen — Success state (done=true)
Replaces whole screen: container absolute inset0 background var(--cream), flex column center/center, padding 30. Badge stack 104x104 centered: pulsing ring absolute inset0 r999 background var(--income) #1F9D6B animation sc-ring 1.1s ease-out .1s; badge 92x92 r28 background var(--income) centered, animation sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both, boxShadow 0 14px 30px -10px var(--income). Checkmark SVG 50x50 viewBox 0 0 24 24, path M5 12.5 10 17.5 19.5 7 stroke #fff strokeWidth 2.8 round caps, strokeDasharray 48, animation sc-check .5s .35s ease-out both. Title 'Card added!' fontSize 23 weight 700 font-family var(--display) marginTop 24, animation sc-fade-up .4s .35s both. Subtext marginTop 6 fontSize 14.5 color var(--ink-2) center lh1.45, animation sc-fade-up .4s .45s both: '<strong ink>{sel.name or "Your card"}</strong> is now in your wallet.' Done button: marginTop 28 full-width height 54 radius 17 background var(--accent) color #fff 16/700, animation sc-fade-up .4s .55s both; onClick -> onClose.

_Components & tokens:_ income badge 92 r28 sh income; ring sc-ring; check sc-check; title 23/700 display; Done h54 r17 accent

### LoyaltyCardDetail — Immersive container
Returns null if no card. Else absolute inset0, background linear-gradient(165deg, card.c1, card.c2) (immersive full-bleed brand color), flex column, animation sc-rise .3s. Top bar padding 54/18/0, flex space-between align center. LEFT: close button 40x40 radius 999 (CIRCLE) background rgba(255,255,255,.2) backdrop-blur 8px, Icon close size20 #fff. RIGHT: points pill fontSize 11.5 weight700 color #fff background rgba(255,255,255,.2) padding 6px 12px radius 999 nowrap = card.pts.

_Components & tokens:_ immersive grad165(c1,c2); close circle r999 white20 blur8; pts pill white20

### LoyaltyCardDetail — Center content
flex1 column center/center padding 0 22px, text-align center. Brand name color #fff font-family var(--display) weight700 fontSize 30 letter-spacing -0.5. Sub color rgba(255,255,255,.8) fontSize14 marginTop3. LARGE scannable barcode panel: background #fff radius 20 padding 22px 22px 18px, marginTop 28, width 100% maxWidth 320, boxShadow 0 24px 50px -20px rgba(0,0,0,.5). Inner barcode height 120 backgroundImage repeating-linear-gradient(90deg,#111 0 2px,transparent 2px 4px,#111 4px 7px,transparent 7px 10px,#111 10px 12px,transparent 12px 17px) — REPLACE with REAL high-contrast barcode in v1. Number under barcode marginTop16 fontSize17 weight700 color #111 tabular-nums letter-spacing2. Brightness note: marginTop24 flex row align center gap7 color rgba(255,255,255,.85) fontSize13.5 weight500: Icon sparkles size16 #fff FILLED + 'Screen brightness boosted for scanning'.

_Components & tokens:_ brand 30/700 display ls-0.5; white barcode panel r20 maxW320 sh 0 24px 50px -20px black50; barcode h120; num 17/700 #111 tabular ls2; brightness note 13.5/500 white85

### LoyaltyCardDetail — Footer actions
padding 0 18px 40px, flex row gap10. Share button: flex1 height54 radius17 background rgba(255,255,255,.95) color card.c2 (deep brand) fontSize16 weight700 flex center gap8 nowrap: Icon share size19 color card.c2 + 'Share'. Done button: flex1 height54 radius17 background rgba(255,255,255,.16) 1px solid rgba(255,255,255,.3) color #fff 16/700 nowrap; onClick -> onClose.

_Components & tokens:_ Share h54 r17 white95 text=c2; Done h54 r17 white16 border white30 #fff

## Interactions
- **Tap back button (arrowLeft) on LoyaltyScreen** -> Calls onClose — dismiss wallet overlay back to previous screen
- **Tap accent + button (top-right) on LoyaltyScreen** -> Calls onAdd — opens AddLoyaltyScreen overlay (sc-rise in)
- **Tap a LoyaltyCard in the list** -> Calls onOpen(card) — opens LoyaltyCardDetail full-screen for that card (sc-rise in)
- **Tap 'Add a card' dashed button** -> Calls onAdd — same as + button, opens AddLoyaltyScreen
- **Tap back (arrowLeft) on AddLoyaltyScreen** -> Calls onClose — dismiss Add overlay
- **Tap 'Scan card barcode' dark CTA** -> No handler in prototype; in v1 launches camera barcode scanner (VisionKit/Vision) to read a real loyalty barcode and prefill brand+number
- **Type in 'Search 300+ brands' field** -> Filters/searches brand catalog (no live handler in prototype; static grid shown)
- **Tap a brand tile in grid** -> setSel(brand) — selects brand: tile border switches to brand color (1.5px) + on-select shadow 0 8px 18px -10px brandColor; reveals the number field (sc-fade-up .3s); enables footer CTA
- **Type in 'Enter card number' input** -> setNum(value), inputMode numeric — stores entered member number
- **Tap 'Add to wallet' footer CTA** -> Disabled until a brand selected; when enabled setDone(true) -> shows success state. In v1: persist new LoyaltyCard (brand, color, number) to SwiftData + sync queue
- **Tap 'Done' on success state** -> Calls onClose — dismiss Add flow back to wallet (new card now present)
- **Tap close (X circle) on LoyaltyCardDetail** -> Calls onClose — dismiss detail back to wallet
- **Tap 'Share' on LoyaltyCardDetail** -> No handler in prototype; in v1 opens share sheet (e.g. share card image / number / pass)
- **Tap 'Done' on LoyaltyCardDetail** -> Calls onClose — dismiss detail back to wallet
- **Open LoyaltyCardDetail (mount)** -> In v1: boost screen brightness to max for scannability, restore on dismiss (the 'Screen brightness boosted for scanning' note signals this)

## States
- LoyaltyScreen populated: 4 seed cards rendered from CARDS array. NOTE prototype has no empty state — v1 should add an EmptyArt illustration + 'Add a card' prompt when wallet has zero cards.
- AddLoyaltyScreen default: brand grid shown, no brand selected (sel=null) -> number field hidden, footer CTA DISABLED (gray var(--line) bg, var(--ink-3) text, no shadow).
- AddLoyaltyScreen brand-selected: sel set -> selected tile highlighted (brand-color border + tinted shadow), number field appears (sc-fade-up), CTA ENABLED (accent bg, white text, accent shadow).
- AddLoyaltyScreen success (done=true): full-screen confirmation with animated income badge + checkmark + 'Card added!' + brand name + Done button.
- LoyaltyCardDetail null guard: if card is null component returns null (renders nothing).
- No explicit loading or error states in prototype. v1 to add: loading/saving spinner on 'Add to wallet' during persist+sync; error toast/inline if save or scan fails; barcode-generation failure fallback (show number-only).

## Animations
- sc-rise (0.30s cubic-bezier(.22,.61,.36,1) both): entry for LoyaltyScreen, AddLoyaltyScreen, and LoyaltyCardDetail containers — opacity 0->1, translateY 14px->0, scale .98->1.
- sc-fade-up (0.30s both): number-field wrapper reveal when a brand is selected (opacity 0->1, translateY 10px->0).
- sc-fade-up (0.40s, staggered delays .35s/.45s/.55s, both): success-state title, subtext, and Done button enter sequentially.
- sc-pop-in (0.50s cubic-bezier(.34,1.56,.64,1) both): success income badge pops with overshoot (scale .5->1.08->1, opacity 0->1).
- sc-ring (1.1s ease-out .1s): success badge expanding pulse ring behind the badge (scale .6->1.5, opacity .55->0).
- sc-check (0.50s .35s ease-out both): success checkmark stroke draw-on (stroke-dashoffset 48->0, dasharray 48).
- Brand-tile transition (all .18s): border-color + shadow change on selection.
- Footer CTA transition (all .2s): background/color/shadow change between disabled and enabled.
- NOTE: no exit animations defined — dismiss is instant in prototype; v1 should add reverse transitions.

## Data fields
- READ (LoyaltyCard / CARDS): brand (string), sub (string — parent group, e.g. 'Woolworths'), num (member/barcode number string), pts (display string: '2,140 pts' | '8,905 pts' | '1,260 credits' | '$12 rewards'), c1 (brand gradient start hex), c2 (brand gradient end hex)
- READ (BRANDS picker): name (string), i (initials/monogram string e.g. 'ER','fb','M'), c (single brand color hex)
- WRITTEN (AddLoyaltyScreen state): sel (selected brand object {name,i,c} | null), num (entered card number string), done (bool)
- v1 persisted LoyaltyCard model fields (SwiftData): id, brand name, sub/group, member number (barcode payload), barcode symbology (Code128/EAN13/QR etc.), brand color(s) c1/c2, points display, createdAt, updatedAt, soft-delete tombstone, owner profile id
- v1 derived: real barcode image generated from member number; points auto-matched from scanned receipts (per the hint card)

## Components: LoyaltyCard (custom branded card button: gradient bg, deco circle, brand+sub, points Chip-like pill, mini barcode strip, member number), Square icon button (40x40 r12 paper+line) — back / header actions, Accent square FAB (40x40 r12 accent) — header +, IconCircle/Chip primitives (theme): points pills use Chip-like rounded-999 translucent style, Dashed secondary button ('Add a card'), Info/hint Card (paper-2, sparkles + copy), Dark Scan CTA row (ink bg, accent icon tile, chevR), Search field (paper + line, search icon + text input), Brand grid tile (paper card, color monogram chip, label; selectable), Number entry field (paper + line, mini brand chip + numeric input), Sticky gradient footer with primary CTA (disabled/enabled), Success/confirmation view (income badge + sc-ring + sc-check + staged sc-fade-up text + Done), LoyaltyCardDetail immersive full-screen (brand gradient, translucent close + pts pill, large barcode panel, brightness note, Share/Done), Icon (theme line-icon, 24-grid): arrowLeft, plus, sparkles(fill), scan, search, chevR, close, share + custom check SVG
## Color tokens: cream/canvas #FBF6F0 (var(--cream)) — all screen backgrounds except detail, paper #FFFFFF (var(--paper)) — buttons, fields, barcode panels, paper-2 #F6EEE4 (var(--paper-2)) — auto-match hint card, ink #211C18 (var(--ink)) — primary text, dark Scan CTA bg, input text, ink-2 #6B6258 (var(--ink-2)) — secondary text, back-icon color, ink-3 #A99F93 (var(--ink-3)) — placeholders, section labels, disabled CTA text, line #ECE3D8 (var(--line)) — borders, dashed border, disabled CTA bg, r-inner 16 / r-card 22 (radii tokens), accent = active profile palette[0]: Personal #E8602C (p) / Business #0E7C72 (b) — + button, icon tiles, brand chip, enabled CTA, sparkles fill, accent-deep palette[2]: Personal #C2461A (p-deep) / Business #0A5950 (b-deep) — available via token (not directly used here; detail Share text uses card.c2 instead), income #1F9D6B (var(--income)) — success badge + ring + check bg, sh-card = 0 1px 2px rgba(33,28,24,.04), 0 10px 26px -16px rgba(33,28,24,.14) — Scan CTA, search, brand tiles, number field, Card brand colors (CARDS): Everyday Rewards c1 #1A8A3C / c2 #0C5C26; flybuys c1 #1457C7 / c2 #0A2F86; MYER one c1 #2C2C2C / c2 #000000; Sister Club c1 #D8467F / c2 #A82C5E, Brand picker colors (BRANDS): Everyday Rewards #1A8A3C, flybuys #1457C7, MYER one #111111, Sister Club #D8467F, Qantas FF #E40000, Velocity #7A1FA2, Kmart #E51937, BWS #0A7D3E, T2 Tea #1A1A1A, Barcode bars #111 on #fff; card-on-card shadow uses brand c1 tint (0 12px 26px -14px c1), Detail panel shadow 0 24px 50px -20px rgba(0,0,0,.5); detail bg linear-gradient(165deg, c1, c2), Translucent whites: rgba(255,255,255,.08) deco circle, .2 pills/close, .16/.3 Done btn, .6/.5/.8/.85/.95 various text/share

**Navigation:** ENTRY: each screen animates in with sc-rise (0.30s, cubic-bezier(.22,.61,.36,1), both) = opacity 0->1 + translateY(14px->0) + scale(.98->1). Success sub-state of Add uses staged sc-pop-in / sc-ring / sc-check / sc-fade-up instead. EXIT: source has no explicit exit animation (instant dismiss on onClose); for SwiftUI mirror entry in reverse (slide/scale-down + fade ~0.25s). Flow: LoyaltyScreen --[+ or Add a card]--> AddLoyaltyScreen --[Add to wallet]--> success state --[Done]--> dismiss back to LoyaltyScreen. LoyaltyScreen --[tap card]--> LoyaltyCardDetail --[close/Done]--> back to LoyaltyScreen. Back/close buttons (arrowLeft / close) dismiss the current overlay.
**Notes:** BARCODES ARE REAL IN V1: both the mini card-list barcode (height 40, radius 8 white panel) and the detail panel barcode (height 120, white r20 panel) are repeating-linear-gradient placeholders in the prototype — generate ACTUAL scannable barcodes from the stored member number (choose symbology per brand: typically Code128 or EAN; consider CoreImage CIBarcodeGenerator / CICode128BarcodeGenerator, or a barcode lib for EAN/QR). Detail barcode must be high-contrast #111 on #fff, large, and centered.\n\nSCREEN BRIGHTNESS: implement the 'Screen brightness boosted for scanning' note — set UIScreen.main.brightness to max on LoyaltyCardDetail appear, restore on disappear.\n\nFONTS: brand names / headings / member numbers use --display = Schibsted Grotesk (weight 700, tabular-nums where numbers, letter-spacing tightened: card brand -0.2, detail brand -0.5, success title default). All UI text/inputs use --ui = Hanken Grotesk. Apply font-variant-numeric tabular-nums to all member numbers (card list ls1, detail ls2).\n\nMONOGRAM TILES: brand picker tiles + number-field chip render the brand initials (i) in Schibsted Grotesk 700 on the brand color — replicate; if real brand logos are available in v1 prefer logos, else keep monogram fallback.\n\nThe prototype seeds 4 wallet cards (CARDS) and a 9-brand picker (BRANDS); v1 should source these from a real brand catalog ('Search 300+ brands', 'Popular in Australia' section header). Currency AUD context: one seed points value is '$12 rewards'.\n\nThe success state intentionally uses --income green (not the profile accent) for the badge; only the Done button uses --accent.\n\nNo Tweaks panel relevant here (already dropped per project decisions). Per project: writes are local-first (SwiftData instantly + offline queue), last-write-wins on updatedAt, soft-delete tombstones — apply to add/delete of loyalty cards. Source file: /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/loyalty-page.jsx. Tokens/keyframes confirmed in /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/snapceipt.html and icon glyphs in /Users/yangqi/Documents/github/Snapceipt/design-ref/snapceipt/project/app/theme.jsx.

---

# iOS Device Frame (IOSDevice) + Design System Primitives + Raised-Center Snap Tab Bar. This file pair (ios-frame.jsx + theme.jsx) defines the SwiftUI design-system foundation, not a single user-facing screen. Overlays/components covered: IOSDevice (bezel/status bar/dynamic island/home indicator), IOSStatusBar, IOSGlassPill, IOSNavBar, IOSListRow, IOSList, IOSKeyboard, plus theme primitives (Icon, IconCircle, Card, Chip, Progress, Segmented, Donut, BarPair, EmptyArt) and the TabBar from shell.jsx.

**Route:** Root container. SwiftUI: a root view applying the cream background + accent CSS-var equivalents via Environment, hosting a TabView-equivalent with custom tab bar overlay. The HTML device frame (bezel, status bar, island, home indicator) is a PROTOTYPE simulation — in the real app these are provided by the OS; reproduce only their dimensions/safe-area math, not the drawn chrome.

**Purpose:** Establish the pixel-faithful SwiftUI design-system module: the 402x874 device frame chrome (these are simulated in HTML but in a REAL iOS 17+ build map to actual safe-area insets), the complete color/typography/radii/shadow token set, the line-icon library (24-grid), the reusable primitive components, the 9 animations, and the raised-center Snap tab bar. Every other Snapceipt screen consumes these tokens and primitives.

**Mode-aware:** PERSONAL vs BUSINESS is implemented as a runtime accent re-skin, not separate layouts. mode = active.type (personal|business). The three --accent vars are swapped from the active profile palette: Personal = terracotta [#E8602C / #FDEBE0 / #C2461A]; Business = teal [#0E7C72 / #DCF0ED / #0A5950]. Every accent-driven element instantly recolors: Snap FAB gradient (accent->accent-deep), active tab item color/strokeWidth, Chip active fill, Progress/BarPair expense fill, Segmented (tint default --accent), Donut segments, EmptyArt, --sh-fab tint (color-mix accent 55%). Extra business profiles (Lumen blue, Rentals green) supply their own palettes. Default startup profile = personal. Profiles each keep separate receipts/budgets/tax (per ProfilePickerSheet copy). Switching profile re-keys the screen container (tab+activeId) so the enter animation replays. No light/dark OS-mode switching in the actual app (design system supports dark via IOSDevice dark prop, but screens render light).

## Layout

### Device frame (IOSDevice) — outer shell
Fixed 402x874 canvas. In prototype: rounded rect r=48, overflow hidden, background #F2F2F7 (light) / #000 (dark), drop shadow 0 40px 80px rgba(0,0,0,.18) + 1px ring rgba(0,0,0,.12). In real iOS: this is the screen; use logical points, GeometryReader/safeAreaInsets. App content background is --cream #FBF6F0 (set by app-root, not the #F2F2F7 frame bg).

_Components & tokens:_ width 402, height 874, cornerRadius 48; bg #F2F2F7/#000; sh: 0 40px 80px rgba(0,0,0,.18), 0 0 0 1px rgba(0,0,0,.12); font -apple-system/system-ui

### Dynamic Island (notch)
Absolute pill centered horizontally near top. Black capsule overlaying content, zIndex 50. Real iOS: do not draw; reserve top safe-area. Map: top inset ~59pt on Dynamic Island devices.

_Components & tokens:_ top 11, width 126, height 37, cornerRadius 24, background #000, centered (left 50% translateX -50%)

### Status bar (IOSStatusBar)
Absolute top, zIndex 10 (below island zIndex 50). Row: left cell = time, right cell = signal+wifi+battery glyphs. Time '9:41'. Color #000 (light) / #fff (dark). Real iOS: system-drawn; only reserve height. Container padding 21px top / 24px sides / 19px bottom; gap 154 between the two flex cells; each cell height 22.

_Components & tokens:_ time: font -apple-system/SF Pro, weight 590, size 17, lineHeight 22, color #000/#fff. Signal SVG 19x12 (4 bars rx .7). Wifi SVG 17x12. Battery SVG 27x13: outline rect rx3.5 strokeOpacity .35, fill rect 20x9 rx2, nub fillOpacity .4. Glyph gap 7.

### Nav bar (IOSNavBar) — optional, only when title prop set
Column, gap 10, paddingTop 62, paddingBottom 10, zIndex 5. Top row space-between with two glass pills (back chevron leading, ellipsis trailing). Below: large title. NOTE: Snapceipt's actual app screens do NOT use this iOS nav bar — they use custom headers (home.jsx etc.). Reproduce IOSGlassPill + large-title type only if building generic iOS settings-style pages.

_Components & tokens:_ largeTitle: font -apple-system, size 34, weight 700, lineHeight 41, letterSpacing 0.4, color #000/#fff; row padding 0 16; pill content box 36x36; muted icon color #404040 / rgba(255,255,255,.6)

### Glass pill (IOSGlassPill)
Liquid-glass capsule: height 44, minWidth 44, r 9999, overflow hidden. 3 layers: (1) blur+tint backdropFilter blur(12px) saturate(180%) bg rgba(255,255,255,.5) light / rgba(120,120,128,.28) dark; (2) shine inset highlights + 0.5px border; (3) content zIndex 1 padding 0 4. SwiftUI: .ultraThinMaterial in a Capsule with inner highlight overlay + thin stroke.

_Components & tokens:_ height 44, minWidth 44, radius 999; sh light: 0 1px 3px rgba(0,0,0,.07),0 3px 10px rgba(0,0,0,.06); shine light: inset 1.5px 1.5px 1px rgba(255,255,255,.7), inset -1px -1px 1px rgba(255,255,255,.4); border light 0.5px rgba(0,0,0,.06)

### Raised-center Snap Tab Bar (shell.jsx TabBar)
Absolute bottom, zIndex 40, paddingBottom 22, pointerEvents none on wrapper. Behind bar: full-bleed gradient scrim linear-gradient(transparent, --cream 55%) to fade content under it. Bar: margin 0 16, height 64, r 26, frosted bg rgba(255,255,255,.82) + backdropFilter blur(18px) saturate(180%), 1px --line border, shadow 0 12px 30px -12px rgba(33,28,24,.28), flex space-around, pointerEvents auto. 5 items: Home(home), Activity(receipt), Snap(camera, CENTER RAISED), Reports(chart), Profile(user). Non-center items: flex column, gap 3, icon 23 + label. Active item uses --accent color + strokeWidth 2.1; inactive --ink-3 + strokeWidth 1.8. CENTER Snap button: 58x58, r 20, marginTop -26 (raised above bar), gradient linear-gradient(150deg, --accent, --accent-deep), --sh-fab accent-tinted shadow, 3px solid --cream border, white camera icon size 26. Tapping Snap opens capture overlay (does NOT switch tab).

_Components & tokens:_ bar: h64 r26 bg rgba(255,255,255,.82) blur18/sat180 border 1px #ECE3D8 sh 0 12px 30px -12px rgba(33,28,24,.28); FAB: 58x58 r20 marginTop -26 gradient accent→accent-deep, sh-fab, border 3px #FBF6F0, icon white 26; tab label fontSize 10.5 weight 700; tab icon 23

### Home indicator
Absolute bottom, zIndex 60 (always on top), height 34, paddingBottom 8, pointerEvents none, centered. Real iOS: system-drawn; reserve bottom safe-area ~34pt.

_Components & tokens:_ pill width 139, height 5, radius 100, background rgba(0,0,0,.25) light / rgba(255,255,255,.7) dark

### Keyboard (IOSKeyboard) — optional, only when keyboard prop set
Liquid-glass QWERTY at bottom: r 27, padding 11 top/2 bottom. Layers: blur(12px) saturate(180%) bg rgba(255,255,255,.25), shine inset highlights. Autocorrect bar (3 suggestions, dividers 1x25 #ccc op .3). 4 key rows. Keys h42 r8.5 bg rgba(255,255,255,.85), fontSize 25 weight 458 color #595959. Return key bg #08f white glyph. Real iOS: use the system keyboard; this is prototype-only — skip unless mimicking exact look.

_Components & tokens:_ 

### Grouped list (IOSList/IOSListRow) — optional iOS-style settings
List card: bg #fff, r 26, margin 0 16, overflow hidden. Optional header: fontSize 13, uppercase, color rgba(60,60,67,.6), padding 8 36 6, letterSpacing -0.08. Row: minHeight 52, padding 0 16, fontSize 17, letterSpacing -0.43. Optional 30x30 r7 icon tile (marginRight 12). Title flex; detail muted rgba(60,60,67,.6); chevron 8x14 stroke rgba(60,60,67,.3). Separator 0.5px rgba(60,60,67,.12) inset left 58 (with icon) or 16.

_Components & tokens:_ 

## Interactions
- **Tap a non-center tab item (Home/Activity/Reports/Profile)** -> go(it.id) -> setTab(route), persists localStorage 'sc-tab'; active item recolors to --accent (icon + label) and icon strokeWidth thickens 1.8->2.1; screen container re-keys (tab+activeId) triggering sc-fade-up enter
- **Tap center raised Snap FAB (camera)** -> onSnap() -> setOverlay('capture'); opens CaptureFlow overlay. Does NOT change the selected tab. SwiftUI: present capture full-screen cover/sheet
- **Tap glass pill back chevron (IOSNavBar)** -> prototype: no handler wired; in real app maps to navigation pop / dismiss
- **Tap Chip** -> onClick fires; visual active state toggles (bg fills tint, text -> #fff, shadow appears) with all .18s transition
- **Tap Segmented option** -> onChange(value); sliding thumb translateX animates to selected index over .28s cubic-bezier(.22,.61,.36,1); selected label color --ink-3 -> --ink over .2s
- **Tap Card with onClick** -> invokes provided handler (e.g., open txn detail / overlay)
- **Profile picker select (ProfilePickerSheet)** -> onSelect(id) -> setActive(id) + persist 'sc-active' + close; re-skins accent vars app-wide; selected row shows accent ring + check badge
- **Profile picker 'Add a profile'** -> onAdd -> setOverlay('addProfile')
- **Tap scrim behind ProfilePickerSheet** -> onClose closes the bottom sheet
- **Tap bell / alerts entry** -> go('alerts') -> setOverlay('alerts'); AlertsSheet slides up (sc-rise) showing GST/auto-sort/subscription/budget cards. NOTE per project: alerts stay IN-APP, no emailed reminders
- **Tap key on IOSKeyboard** -> prototype: static, no handler; real app uses system keyboard

## States
- Default/idle: device frame light mode, --cream app background, status bar time '9:41', Personal profile active (terracotta accent)
- Dark mode (IOSDevice dark prop): frame bg #000, status glyphs #fff, home indicator rgba(255,255,255,.7), pills use dark glass recipe — design-system supports it but Snapceipt screens render light
- Tab bar active vs inactive item state (accent vs --ink-3, strokeWidth 2.1 vs 1.8)
- Empty state: EmptyArt illustration (receipt) with --accent-soft circle + plus badge, used by list screens when no data
- Loading/skeleton: sc-shimmer animation (background-position -200%->200%) for shimmer placeholders; sc-pulse for pulsing dots
- Success: sc-check stroke-draw + sc-pop-in + sc-ring + sc-confetti (capture save confirmation)
- Profile-switch transition: screen container re-keys on tab+activeId, replays sc-fade-up enter (.34s)
- Segmented mid-transition: thumb sliding (.28s)
- Progress fill animating width (.6s)
- No explicit error state in these files — design tokens provide --alert #D6452B for error/destructive UI

## Animations
- sc-fade-up (.34s screen-enter / .42s stagger, cubic-bezier(.22,.61,.36,1)) — trigger: screen mount / list item stagger; opacity 0->1 + translateY 10px->0
- sc-fade (.25s) — trigger: scrim/backdrop fade-in; opacity 0->1
- sc-scan — trigger: capture/OCR scanning line; top 4%->92%
- sc-pop-in — trigger: success badge/element appear; scale .5->1.08->1 with opacity
- sc-shimmer — trigger: skeleton loading; background-position -200%->200%
- sc-pulse — trigger: live/recording indicator; opacity .5->1 + scale .9->1.05
- sc-check (keyframe stroke-dashoffset 48->0) — trigger: success checkmark draw
- sc-ring (scale .6->1.5, opacity .55->0) — trigger: success ripple ring
- sc-spin (rotate to 360deg) — trigger: loading spinner
- sc-rise (.3-.32s cubic-bezier(.22,.61,.36,1)) — trigger: sheets/overlays present (AlertsSheet, ProfilePickerSheet); opacity 0 + translateY 14px scale .98 -> settled
- sc-confetti (translateY 0->220px rotate 0->420deg, opacity 1->0) — trigger: budget/goal celebration on save
- Component transitions: Segmented thumb translateX .28s, Progress width .6s, Donut stroke-dasharray .7s, BarPair height .6s, Chip all .18s, Segmented label color .2s (all cubic-bezier(.22,.61,.36,1) where specified)

## Data fields
- TWEAK_DEFAULTS.personalPalette = ['#E8602C','#FDEBE0','#C2461A'] (terracotta p/p-soft/p-deep)
- TWEAK_DEFAULTS.businessPalette = ['#0E7C72','#DCF0ED','#0A5950'] (teal b/b-soft/b-deep)
- Additional profile palettes: Lumen ['#3F5BB0','#E7EAF8','#2C4290'], Rentals ['#2F7A55','#DFF0E6','#205B3D']
- accent vars resolved at runtime: --accent=palette[0], --accent-soft=palette[1], --accent-deep=palette[2] (re-skins whole app on profile switch)
- PROFILES: personal {name:'Maya Reyes', initials:'MR'} ; business {name:'Studio North', initials:'SN'}
- ALL_PROFILES list: personal(P), studio(SN,business), lumen(LS,business), rentals(RP,business); sliced by profileCount
- active tab persisted: localStorage 'sc-tab' (default 'home')
- active profile persisted: localStorage 'sc-active' (default 'personal')
- CATS map: 9 categories each {label, icon, tint hex, soft hex} — meals cup #E8602C/#FBEADF, groceries cart #C99A22/#F6EECE, fuel fuel #2F6FB0/#E2ECF6, software film #7B5BD6/#EBE5F8, office building #0E7C72/#DCF0ED, home home #B0568F/#F4E4EF, health heart #D6452B/#F8E2DD, travel pin #1F9D6B/#DEF3E9, income arrowDown #1F9D6B/#DEF3E9
- SEED transactions (13): fields = id, merchant, cat, amount(+/-), date(ISO), mode(personal|business), tax(label), deductible(%), method, ai(bool), note?, gst(AUD), logbook?
- fmt() AUD currency: minus sign uses U+2212 '−', '$' prefix, en-AU grouping, 2 decimals default; positive sign optional '+'. fmtK(): $X.Xk for >=1000 (no decimal >=10000). fmtDate(): en-AU, default {day:'numeric', month:'short'}
- ICONS: 60+ line-icon path strings on a 24 grid (home, receipt, chart, user, camera, plus, arrowUp/Down/Left/Right, chevR/D, car, wfh, search, check, close, flash, image, sparkles, share, bell, gear, tag, calendar, edit, filter, dots, cup, cart, fuel, software/film, building, bank, doc, wallet, heart, trash, pencil, link, shield, lock, pin, clock, swap, scan, download, info, logout, star, phone)

## Components: IOSDevice (frame 402x874, r48, dynamic island, status bar, home indicator), IOSStatusBar (time + signal/wifi/battery SVG glyphs), IOSGlassPill (liquid-glass capsule h44 r999, blur12 sat180), IOSNavBar (large title 34/700 + leading back pill + trailing ellipsis pill), IOSListRow (h52, icon tile 30 r7, title/detail/chevron, 0.5px separator), IOSList (inset card r26 #fff + uppercase header), IOSKeyboard (liquid-glass QWERTY, keys h42 r8.5, return #08f), TabBar (5-item frosted bar h64 r26 + raised center Snap FAB 58 r20), Card (bg --paper, r22 var(--r-card), sh-card, 1px --line-2 border, pad 16), IconCircle (size 42 r13, soft bg, Icon isize 21 sw 1.9), Chip (pill r999 8x14 pad, fontSize 13.5/600, active=tint bg + #fff text + shadow, inactive=--paper bg + --ink-2 + --line border, transition all .18s), Progress (track --line r999 h8, fill --accent, width transition .6s cubic-bezier(.22,.61,.36,1)), Segmented (animated sliding control, --paper-2 track r999 pad4, sliding thumb --paper translateX .28s cubic-bezier(.22,.61,.36,1), label 14/600), Donut (SVG ring, default size 160 thickness 22, --line track, segments strokeLinecap round with 3px gap, rotate -90deg, stroke-dasharray transition .7s), BarPair (income vs expense bars width 11 r5, --income vs --accent, height transition .6s, default height 120, gap 14, label 11/600 --ink-3), EmptyArt (132 friendly receipt illustration, --accent-soft circle + white receipt + accent plus badge), Icon (line icon, 24 viewBox, default size 22 sw 1.85, fill toggle)
## Color tokens: --cream #FBF6F0 (app canvas), --paper #FFFFFF, --paper-2 #F6EEE4, --ink #211C18, --ink-2 #6B6258, --ink-3 #A99F93, --line #ECE3D8, --line-2 #F3EBE1, --p #E8602C (personal terracotta), --p-soft #FDEBE0, --p-deep #C2461A, --b #0E7C72 (business teal), --b-soft #DCF0ED, --b-deep #0A5950, --income #1F9D6B, --income-soft #DEF3E9, --alert #D6452B, --accent = active palette[0] (defaults to --p), --accent-soft = active palette[1], --accent-deep = active palette[2], Category tints: meals #E8602C/#FBEADF, groceries #C99A22/#F6EECE, fuel #2F6FB0/#E2ECF6, software #7B5BD6/#EBE5F8, office #0E7C72/#DCF0ED, home #B0568F/#F4E4EF, health #D6452B/#F8E2DD, travel #1F9D6B/#DEF3E9, income #1F9D6B/#DEF3E9, Frame chrome (prototype): #F2F2F7 frame bg, #000 island, return key #08f, list secondary rgba(60,60,67,.6), Radii: --r-card 22px, --r-inner 16px, --r-chip 12px, pills/circles 999, Shadows: --sh-card 0 1px 2px rgba(33,28,24,.04),0 10px 26px -16px rgba(33,28,24,.14); --sh-pop 0 8px 24px -8px rgba(33,28,24,.22),0 2px 6px rgba(33,28,24,.08); --sh-fab 0 8px 20px -4px color-mix(accent 55%),0 3px 8px rgba(33,28,24,.18)

**Navigation:** Entry: App mounts inside IOSDevice; root reads persisted tab ('sc-tab', default home) and profile ('sc-active', default personal). Tab switches via TabBar.go(route)->setTab; each switch re-keys the screen wrapper -> sc-fade-up (.34s) enter. Overlays/sheets present over the tab content: capture (Snap FAB), alerts/profilePicker/addProfile/export/categories/tax/banks/mileage/wfh/quote/manual/loyalty* — bottom sheets enter with sc-rise (.32s) + scrim sc-fade (.25s). Exit: sheets dismiss via onClose (tap scrim, back/close button) reversing the rise; capture closes via onClose returning to current tab. TxnDetail presents on go('txn', payload) and dismisses via onClose. No emailed reminders — alerts are an in-app sheet only.
**Notes:** SwiftUI rebuild guidance: (1) The HTML device frame (bezel r48, drawn status bar, dynamic island pill, home indicator) is a PROTOTYPE viewport simulation. In the real iOS 17+ app these are OS-provided — do NOT draw them; instead honor safe-area insets (top ~59pt island, bottom ~34pt home indicator) and reserve the bottom inset so the floating tab bar + raised FAB clear it. The actual app background is --cream #FBF6F0, NOT the #F2F2F7 frame bg. (2) Fonts: map --display 'Schibsted Grotesk' (numbers/headings; apply tabular figures + letterSpacing -0.01em via .num class; weights used 400/500/600/700/800) and --ui 'Hanken Grotesk' (UI body; weights 400/500/600/700). Bundle both as custom fonts; SwiftUI: Font.custom with .monospacedDigit() for .num. Display weights seen: 700/800 headings, 590-equivalent for iOS time only (system font). (3) The status-bar/keyboard/navbar/list iOS primitives are generic chrome — only build the ones you actually mimic (likely none, since real OS chrome is used); they are documented here for completeness. (4) Build the raised-center tab bar as a custom overlay: 5 items, center item raised marginTop -26 with -26pt offset, accent gradient FAB, 3pt --cream ring, sh-fab. Behind it lay a top-transparent->cream linear gradient scrim so scrolling content fades out. pointerEvents: wrapper passes through, bar + FAB are tappable. (5) color-mix in --sh-fab: compute accent at 55% opacity for the FAB glow (SwiftUI: accent.opacity(0.55) shadow). (6) Animations -> SwiftUI: cubic-bezier(.22,.61,.36,1) ~ Animation.timingCurve(0.22,0.61,0.36,1); durations as listed. (7) Per project decisions: drop the Tweaks panel and its variants; palette is fixed (terracotta/teal) not user-tweakable in v1. (8) AUD formatting must use U+2212 minus and en-AU grouping; GST values are stored per-transaction; tabular-nums essential for column alignment. (9) icon stroke-weight variants (icons-thin sw 1.45, icons-bold sw 2.4, regular default 1.85) come from iconStyle tweak — with tweaks dropped, use regular sw 1.85 (active tab item bumps to 2.1).

---

