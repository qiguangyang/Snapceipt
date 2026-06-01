// theme.jsx — Snapceipt design system: icons, formatters, data, primitives
// Exported to window at the bottom.

// ── Money / date formatting (AUD) ─────────────────────────────
const fmt = (n, { sign = false, cents = true } = {}) => {
  const abs = Math.abs(n);
  const s = abs.toLocaleString('en-AU', {
    minimumFractionDigits: cents ? 2 : 0,
    maximumFractionDigits: cents ? 2 : 0,
  });
  const pre = n < 0 ? '−' : (sign && n > 0 ? '+' : '');
  return pre + '$' + s;
};
const fmtK = (n) => {
  const a = Math.abs(n);
  if (a >= 1000) return '$' + (a / 1000).toFixed(a >= 10000 ? 0 : 1) + 'k';
  return '$' + a.toFixed(0);
};
const fmtDate = (iso, opt = { day: 'numeric', month: 'short' }) =>
  new Date(iso + 'T00:00:00').toLocaleDateString('en-AU', opt);

// ── Icon set (line icons, 24 grid, rounded) ───────────────────
const ICONS = {
  home: 'M3 10.6 12 4l9 6.6M5.5 9.2V19a1 1 0 0 0 1 1H10v-5h4v5h3.5a1 1 0 0 0 1-1V9.2',
  receipt: 'M6 3h12v18l-2.2-1.4L13.6 21 12 19.6 10.4 21 8.2 19.6 6 21V3ZM9 8h6M9 12h6M9 16h3',
  chart: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
  user: 'M12 12.6a4.1 4.1 0 1 0 0-8.2 4.1 4.1 0 0 0 0 8.2ZM4.6 20a7.5 7.5 0 0 1 14.8 0',
  camera: 'M3.5 8.5A2 2 0 0 1 5.5 6.5h1.7l1-1.7a1 1 0 0 1 .9-.5h5.8a1 1 0 0 1 .9.5l1 1.7h1.7a2 2 0 0 1 2 2v8.5a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2V8.5ZM12 17a3.7 3.7 0 1 0 0-7.4 3.7 3.7 0 0 0 0 7.4Z',
  plus: 'M12 5v14M5 12h14',
  arrowUp: 'M12 19V5M6 11l6-6 6 6',
  arrowDown: 'M12 5v14M6 13l6 6 6-6',
  arrowRight: 'M5 12h14M13 6l6 6-6 6',
  arrowLeft: 'M19 12H5M11 6l-6 6 6 6',
  chevR: 'M9 6l6 6-6 6',
  chevD: 'M6 9l6 6 6-6',
  car: 'M5 16.5h14M5.5 16.5v2M18.5 16.5v2M4.5 16.5l1.2-5a2 2 0 0 1 1.9-1.4h8.8a2 2 0 0 1 1.9 1.4l1.2 5M4.5 16.5h15M7.5 13.5h2M14.5 13.5h2',
  wfh: 'M3 11 12 4.5 21 11M5 9.7V19a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V9.7M9.5 20v-4.2a2.5 2.5 0 0 1 5 0V20',
  search: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14ZM20 20l-4-4',
  check: 'M5 12.5 10 17.5 19.5 7',
  close: 'M6 6l12 12M18 6 6 18',
  flash: 'M13 3 5 13h6l-1 8 8-10h-6l1-8Z',
  image: 'M4 5.5h16v13H4zM4 15l4-4 4 4 3-3 5 5M9 9.5a1.3 1.3 0 1 0 0-2.6 1.3 1.3 0 0 0 0 2.6Z',
  sparkles: 'M12 3l1.7 4.6L18.3 9.3 13.7 11 12 15.6 10.3 11 5.7 9.3 10.3 7.6 12 3ZM18.5 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2Z',
  share: 'M12 15V4M8.5 7.5 12 4l3.5 3.5M5 12v6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-6',
  bell: 'M6.5 10a5.5 5.5 0 0 1 11 0c0 5 2 6.5 2 6.5H4.5s2-1.5 2-6.5ZM9.5 19.5a2.6 2.6 0 0 0 5 0',
  gear: 'M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4ZM19.4 12c0-.5-.05-1-.13-1.46l1.7-1.32-1.9-3.3-2 .8a7.5 7.5 0 0 0-2.5-1.45L14.2 3h-4.4l-.3 2.27A7.5 7.5 0 0 0 7 6.72l-2-.8-1.9 3.3 1.7 1.32a7.7 7.7 0 0 0 0 2.92l-1.7 1.32 1.9 3.3 2-.8a7.5 7.5 0 0 0 2.5 1.45L9.8 21h4.4l.3-2.27a7.5 7.5 0 0 0 2.5-1.45l2 .8 1.9-3.3-1.7-1.32c.08-.46.13-.96.13-1.46Z',
  tag: 'M4 4h7.5l8 8-7.5 7.5-8-8V4ZM8 8.5a.9.9 0 1 0 0-1.8.9.9 0 0 0 0 1.8Z',
  calendar: 'M4.5 6.5h15v13h-15zM4.5 10h15M8 4v4M16 4v4',
  edit: 'M4 20h4L19 9l-4-4L4 16v4ZM14 6l4 4',
  filter: 'M4 6h16M7 12h10M10 18h4',
  dots: 'M5 12h.01M12 12h.01M19 12h.01',
  cup: 'M5 8h12v4a6 6 0 0 1-12 0V8ZM17 9h2.5a2 2 0 0 1 0 4H17M5 20h12',
  cart: 'M3 4h2.5l2 11h10l2-8H7M9 20a1.3 1.3 0 1 0 0-2.6A1.3 1.3 0 0 0 9 20ZM17 20a1.3 1.3 0 1 0 0-2.6 1.3 1.3 0 0 0 0 2.6Z',
  fuel: 'M5 20V6a2 2 0 0 1 2-2h5a2 2 0 0 1 2 2v14M4 20h11M14 9h2.5a1.5 1.5 0 0 1 1.5 1.5V16a1.5 1.5 0 0 0 3 0V8l-2.5-2.5M7 8h5',
  building: 'M5 20V5a1 1 0 0 1 1-1h7a1 1 0 0 1 1 1v15M14 20V9h4a1 1 0 0 1 1 1v10M4 20h16M8 8h3M8 12h3M8 16h3',
  bank: 'M4 9.5 12 4l8 5.5M5 10v8M9 10v8M15 10v8M19 10v8M3.5 20.5h17',
  doc: 'M6.5 3.5h7l4.5 4.5v12a1 1 0 0 1-1 1h-10.5a1 1 0 0 1-1-1v-15a1 1 0 0 1 1-1ZM13 3.5V8h4.5M9 13h6M9 16.5h4',
  wallet: 'M4 7.5A1.5 1.5 0 0 1 5.5 6H18a1 1 0 0 1 1 1v1.5M4 7.5V18a1 1 0 0 0 1 1h13a1 1 0 0 0 1-1v-3.5M4 7.5h14.5M16 11.5h3.5v3H16a1.5 1.5 0 0 1 0-3Z',
  heart: 'M12 19.5S4.5 14.8 4.5 9.4A3.9 3.9 0 0 1 12 7.6 3.9 3.9 0 0 1 19.5 9.4c0 5.4-7.5 10.1-7.5 10.1Z',
  film: 'M4 5h16v14H4zM4 9h16M4 15h16M8 5v14M16 5v14',
  trash: 'M5 7h14M9 7V4.5h6V7M7 7l1 13h8l1-13',
  pencil: 'M4 20h4L19 9l-4-4L4 16v4ZM14 6l4 4',
  link: 'M9.5 14.5 14.5 9.5M10.5 7.5 12 6a3.5 3.5 0 0 1 5 5l-1.5 1.5M13.5 16.5 12 18a3.5 3.5 0 0 1-5-5l1.5-1.5',
  shield: 'M12 3.5 5 6v5.5c0 4.4 3 7.5 7 9 4-1.5 7-4.6 7-9V6l-7-2.5ZM9 12l2 2 4-4',
  lock: 'M6.5 11V8.5a5.5 5.5 0 0 1 11 0V11M5.5 11h13a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1h-13a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1Z',
  pin: 'M12 21s7-5.5 7-11a7 7 0 1 0-14 0c0 5.5 7 11 7 11ZM12 12.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z',
  clock: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 7.5V12l3 2',
  swap: 'M7 7h11l-3-3M17 17H6l3 3',
  scan: 'M4 8V5.5a1.5 1.5 0 0 1 1.5-1.5H8M16 4h2.5A1.5 1.5 0 0 1 20 5.5V8M20 16v2.5a1.5 1.5 0 0 1-1.5 1.5H16M8 20H5.5A1.5 1.5 0 0 1 4 18.5V16M7 12h10',
  download: 'M12 4v11M7.5 10.5 12 15l4.5-4.5M5 19h14',
  info: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 11v5M12 7.6h.01',
  logout: 'M14 7V5a1 1 0 0 0-1-1H6a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1v-2M9.5 12h11M17 8.5l3.5 3.5L17 15.5',
  star: 'M12 3.5l2.6 5.3 5.9.86-4.25 4.14 1 5.85L12 17.1l-5.25 2.6 1-5.85L3.5 9.66l5.9-.86L12 3.5Z',
  phone: 'M7 4.5 9 4l1.5 4-2 1.5a11 11 0 0 0 5 5l1.5-2 4 1.5-.5 2a2 2 0 0 1-2 1.6A15 15 0 0 1 5.4 6.5a2 2 0 0 1 1.6-2Z',
};

function Icon({ name, size = 22, color = 'currentColor', sw = 1.85, fill = false, style = {} }) {
  const d = ICONS[name];
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" className="sc-ic"
      style={{ display: 'block', flexShrink: 0, ...style }}>
      <path d={d}
        stroke={fill ? 'none' : color}
        fill={fill ? color : 'none'}
        strokeWidth={sw} strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

// ── Categories ────────────────────────────────────────────────
const CATS = {
  meals:     { label: 'Meals & Coffee', icon: 'cup',      tint: '#E8602C', soft: '#FBEADF' },
  groceries: { label: 'Groceries',      icon: 'cart',     tint: '#C99A22', soft: '#F6EECE' },
  fuel:      { label: 'Fuel & Transport',icon: 'fuel',    tint: '#2F6FB0', soft: '#E2ECF6' },
  software:  { label: 'Software & Subs', icon: 'film',    tint: '#7B5BD6', soft: '#EBE5F8' },
  office:    { label: 'Office & Supplies',icon:'building', tint: '#0E7C72', soft: '#DCF0ED' },
  home:      { label: 'Home & Utilities',icon: 'home',    tint: '#B0568F', soft: '#F4E4EF' },
  health:    { label: 'Health',          icon: 'heart',   tint: '#D6452B', soft: '#F8E2DD' },
  travel:    { label: 'Travel & Stays',  icon: 'pin',     tint: '#1F9D6B', soft: '#DEF3E9' },
  income:    { label: 'Income',          icon: 'arrowDown',tint: '#1F9D6B', soft: '#DEF3E9' },
};

// ── Seed transactions ─────────────────────────────────────────
const SEED = [
  { id: 't1', merchant: 'The Grounds of Alexandria', cat: 'meals', amount: -42.50, date: '2026-05-28', mode: 'business', tax: 'Client meeting', deductible: 50, method: 'Amex Business', ai: true, note: 'Coffee w/ design client', gst: 3.86 },
  { id: 't2', merchant: 'Apple — Final Cut Pro', cat: 'software', amount: -499.00, date: '2026-05-27', mode: 'business', tax: 'Software', deductible: 100, method: 'Amex Business', ai: true, gst: 45.36 },
  { id: 't3', merchant: 'BP Service Station', cat: 'fuel', amount: -88.20, date: '2026-05-26', mode: 'business', tax: 'Vehicle', deductible: 100, method: 'Visa •2241', ai: true, gst: 8.02, logbook: 'vehicle' },
  { id: 't4', merchant: 'Studio retainer — Northwind', cat: 'income', amount: 4200.00, date: '2026-05-25', mode: 'business', tax: 'Invoice #1042', method: 'Bank transfer', ai: false },
  { id: 't5', merchant: 'Woolworths Metro', cat: 'groceries', amount: -64.85, date: '2026-05-25', mode: 'personal', method: 'Visa •2241', ai: true, gst: 0 },
  { id: 't6', merchant: 'Officeworks', cat: 'office', amount: -129.95, date: '2026-05-24', mode: 'business', tax: 'Supplies', deductible: 100, method: 'Amex Business', ai: true, gst: 11.81 },
  { id: 't7', merchant: 'Adobe Creative Cloud', cat: 'software', amount: -76.99, date: '2026-05-22', mode: 'business', tax: 'Software', deductible: 100, method: 'Amex Business', ai: false, gst: 7.00 },
  { id: 't8', merchant: 'Uber', cat: 'fuel', amount: -23.40, date: '2026-05-21', mode: 'business', tax: 'Travel', deductible: 100, method: 'Visa •2241', ai: true, gst: 2.13 },
  { id: 't9', merchant: 'Chemist Warehouse', cat: 'health', amount: -34.10, date: '2026-05-20', mode: 'personal', method: 'Visa •2241', ai: true, gst: 0 },
  { id: 't10', merchant: 'Qantas — SYD→MEL', cat: 'travel', amount: -312.00, date: '2026-05-18', mode: 'business', tax: 'Travel', deductible: 100, method: 'Amex Business', ai: true, gst: 28.36 },
  { id: 't11', merchant: 'Single Origin Roasters', cat: 'meals', amount: -18.00, date: '2026-05-17', mode: 'personal', method: 'Apple Pay', ai: true, gst: 0 },
  { id: 't12', merchant: 'Energy Australia', cat: 'home', amount: -184.30, date: '2026-05-15', mode: 'personal', method: 'Direct debit', ai: false, gst: 16.75 },
  { id: 't13', merchant: 'Workshop fee — Lumen Co', cat: 'income', amount: 850.00, date: '2026-05-12', mode: 'business', tax: 'Invoice #1041', method: 'Bank transfer', ai: false },
];

// ── Primitives ────────────────────────────────────────────────
function Card({ children, style = {}, pad = 16, onClick, className = '' }) {
  return (
    <div onClick={onClick} className={className} style={{
      background: 'var(--paper)', borderRadius: 'var(--r-card)',
      boxShadow: 'var(--sh-card)', padding: pad,
      border: '1px solid var(--line-2)',
      ...style,
    }}>{children}</div>
  );
}

function IconCircle({ name, tint = 'var(--accent)', soft, size = 42, isize = 21, fill = false }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: 13, flexShrink: 0,
      background: soft || 'var(--accent-soft)',
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }}>
      <Icon name={name} size={isize} color={tint} fill={fill} sw={1.9} />
    </div>
  );
}

function Chip({ children, active, tint = 'var(--accent)', onClick, style = {} }) {
  return (
    <button onClick={onClick} style={{
      display: 'inline-flex', alignItems: 'center', gap: 6,
      padding: '8px 14px', borderRadius: 999, fontSize: 13.5, fontWeight: 600,
      whiteSpace: 'nowrap', transition: 'all .18s',
      background: active ? tint : 'var(--paper)',
      color: active ? '#fff' : 'var(--ink-2)',
      border: active ? '1px solid ' + tint : '1px solid var(--line)',
      boxShadow: active ? '0 4px 12px -6px ' + 'rgba(33,28,24,.3)' : 'none',
      ...style,
    }}>{children}</button>
  );
}

function Progress({ value, max = 100, tint = 'var(--accent)', track = 'var(--line)', h = 8 }) {
  const pct = Math.max(0, Math.min(100, (value / max) * 100));
  return (
    <div style={{ height: h, borderRadius: 999, background: track, overflow: 'hidden' }}>
      <div style={{
        width: pct + '%', height: '100%', borderRadius: 999, background: tint,
        transition: 'width .6s cubic-bezier(.22,.61,.36,1)',
      }} />
    </div>
  );
}

// Segmented control (generic)
function Segmented({ options, value, onChange, tint = 'var(--accent)', style = {} }) {
  const idx = Math.max(0, options.findIndex(o => o.value === value));
  return (
    <div style={{
      position: 'relative', display: 'grid',
      gridTemplateColumns: `repeat(${options.length},1fr)`,
      background: 'var(--paper-2)', borderRadius: 999, padding: 4, ...style,
    }}>
      <div style={{
        position: 'absolute', top: 4, bottom: 4, left: 4,
        width: `calc((100% - 8px) / ${options.length})`,
        transform: `translateX(${idx * 100}%)`,
        background: 'var(--paper)', borderRadius: 999,
        boxShadow: '0 2px 6px -2px rgba(33,28,24,.18)',
        transition: 'transform .28s cubic-bezier(.22,.61,.36,1)',
      }} />
      {options.map(o => (
        <button key={o.value} onClick={() => onChange(o.value)} style={{
          position: 'relative', zIndex: 1, padding: '9px 4px',
          fontSize: 14, fontWeight: 600, letterSpacing: -0.1,
          color: o.value === value ? 'var(--ink)' : 'var(--ink-3)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6,
          transition: 'color .2s',
        }}>{o.label}</button>
      ))}
    </div>
  );
}

// Donut chart (SVG)
function Donut({ segments, size = 160, thickness = 22, children }) {
  const r = (size - thickness) / 2;
  const C = 2 * Math.PI * r;
  const total = segments.reduce((s, x) => s + x.value, 0) || 1;
  let acc = 0;
  return (
    <div style={{ position: 'relative', width: size, height: size }}>
      <svg width={size} height={size} style={{ transform: 'rotate(-90deg)' }}>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--line)" strokeWidth={thickness} />
        {segments.map((s, i) => {
          const len = (s.value / total) * C;
          const off = acc;
          acc += len;
          return (
            <circle key={i} cx={size / 2} cy={size / 2} r={r} fill="none"
              stroke={s.tint} strokeWidth={thickness} strokeLinecap="round"
              strokeDasharray={`${Math.max(len - 3, 0)} ${C}`}
              strokeDashoffset={-off}
              style={{ transition: 'stroke-dasharray .7s cubic-bezier(.22,.61,.36,1)' }} />
          );
        })}
      </svg>
      <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center' }}>
        {children}
      </div>
    </div>
  );
}

// Mini bar chart (income vs expense per month)
function BarPair({ data, height = 120 }) {
  const max = Math.max(...data.flatMap(d => [d.income, d.expense]), 1);
  return (
    <div style={{ display: 'flex', alignItems: 'flex-end', gap: 14, height, padding: '0 2px' }}>
      {data.map((d, i) => (
        <div key={i} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 7 }}>
          <div style={{ display: 'flex', gap: 4, alignItems: 'flex-end', height: height - 22, width: '100%', justifyContent: 'center' }}>
            <div style={{ width: 11, height: (d.income / max) * (height - 22), background: 'var(--income)', borderRadius: 5, transition: 'height .6s' }} />
            <div style={{ width: 11, height: (d.expense / max) * (height - 22), background: 'var(--accent)', borderRadius: 5, transition: 'height .6s' }} />
          </div>
          <div style={{ fontSize: 11, color: 'var(--ink-3)', fontWeight: 600 }}>{d.label}</div>
        </div>
      ))}
    </div>
  );
}

// Friendly empty-state illustration
function EmptyArt({ kind = 'receipt', size = 132 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 132 132" fill="none">
      <circle cx="66" cy="66" r="60" fill="var(--accent-soft)" />
      <rect x="44" y="34" width="44" height="64" rx="6" fill="#fff" stroke="var(--accent)" strokeWidth="2.4" transform="rotate(-6 66 66)" />
      <g transform="rotate(-6 66 66)" stroke="var(--accent)" strokeWidth="2.2" strokeLinecap="round" opacity=".55">
        <path d="M52 48h28M52 58h28M52 68h20" />
      </g>
      <circle cx="92" cy="92" r="17" fill="var(--accent)" />
      <path d="M92 85v14M85 92h14" stroke="#fff" strokeWidth="2.8" strokeLinecap="round" />
    </svg>
  );
}

Object.assign(window, {
  fmt, fmtK, fmtDate, Icon, ICONS, CATS, SEED,
  Card, IconCircle, Chip, Progress, Segmented, Donut, BarPair, EmptyArt,
});
