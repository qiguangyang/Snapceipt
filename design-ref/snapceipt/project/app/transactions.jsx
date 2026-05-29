// transactions.jsx — list, filters, search, and detail
const { useState: useStateT } = React;

function groupByDate(list) {
  const groups = {};
  list.forEach(t => { (groups[t.date] = groups[t.date] || []).push(t); });
  return Object.keys(groups).sort((a, b) => b.localeCompare(a)).map(d => ({ date: d, items: groups[d] }));
}

function dayLabel(iso) {
  const d = new Date(iso + 'T00:00:00');
  const today = new Date('2026-05-29T00:00:00');
  const diff = Math.round((today - d) / 86400000);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Yesterday';
  return d.toLocaleDateString('en-AU', { weekday: 'long', day: 'numeric', month: 'long' });
}

function TransactionsScreen({ txns, mode, go }) {
  const [kind, setKind] = useStateT('all'); // all | expense | income
  const [q, setQ] = useStateT('');
  const [monthKey, setMonthKey] = useStateT('2026-05');
  const [pickerOpen, setPickerOpen] = useStateT(false);

  const MONTHS = [];
  for (let i = 0; i < 8; i++) {
    const d = new Date(2026, 4 - i, 1);
    MONTHS.push(`${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`);
  }
  const monthLabel = (key) => {
    const [y, mm] = key.split('-');
    return new Date(+y, +mm - 1, 1).toLocaleDateString('en-AU', { month: 'short', year: 'numeric' });
  };

  let list = txns.filter(t => t.mode === mode);
  if (monthKey) list = list.filter(t => t.date.slice(0, 7) === monthKey);
  if (kind === 'expense') list = list.filter(t => t.amount < 0);
  if (kind === 'income') list = list.filter(t => t.amount > 0);
  if (q.trim()) list = list.filter(t => (t.merchant + ' ' + CATS[t.cat].label).toLowerCase().includes(q.toLowerCase()));

  const total = list.reduce((s, t) => s + t.amount, 0);
  const groups = groupByDate(list);

  return (
    <div className="scroll" style={{ height: '100%', padding: '54px 0 124px' }}>
      <div style={{ padding: '0 18px' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <h1 style={{ fontFamily: 'var(--display)', fontSize: 30, fontWeight: 700, letterSpacing: -0.6, margin: 0 }}>Activity</h1>
          <div style={{ position: 'relative' }}>
            <button onClick={() => setPickerOpen(o => !o)} style={{ height: 42, padding: '0 12px 0 13px', borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', gap: 7, boxShadow: 'var(--sh-card)', fontFamily: 'var(--ui)', fontWeight: 700, fontSize: 13.5, color: 'var(--ink)' }}>
              <Icon name="calendar" size={18} color="var(--accent)" />
              <span style={{ whiteSpace: 'nowrap' }}>{monthLabel(monthKey)}</span>
              <Icon name="chevD" size={15} color="var(--ink-3)" style={{ transform: pickerOpen ? 'rotate(180deg)' : 'none', transition: 'transform .2s' }} />
            </button>
            {pickerOpen && (
              <>
                <div onClick={() => setPickerOpen(false)} style={{ position: 'fixed', inset: 0, zIndex: 5 }} />
                <div style={{ position: 'absolute', top: 50, right: 0, zIndex: 6, width: 210, background: 'var(--paper)', borderRadius: 16, boxShadow: 'var(--sh-pop)', border: '1px solid var(--line)', padding: 6, animation: 'sc-fade-up .2s both' }}>
                  <div style={{ fontSize: 11.5, color: 'var(--ink-3)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: 0.3, padding: '6px 10px 8px' }}>Select month</div>
                  {MONTHS.map(key => {
                    const on = key === monthKey;
                    return (
                      <button key={key} onClick={() => { setMonthKey(key); setPickerOpen(false); }} style={{ display: 'flex', width: '100%', alignItems: 'center', justifyContent: 'space-between', padding: '10px 12px', borderRadius: 10, background: on ? 'var(--accent-soft)' : 'transparent', color: on ? 'var(--accent-deep)' : 'var(--ink)', fontWeight: 600, fontSize: 14.5, fontFamily: 'var(--ui)' }}>
                        {monthLabel(key)}
                        {on && <Icon name="check" size={16} color="var(--accent)" sw={2.6} />}
                      </button>
                    );
                  })}
                </div>
              </>
            )}
          </div>
        </div>

        {/* search */}
        <div style={{ marginTop: 14, display: 'flex', alignItems: 'center', gap: 9, background: 'var(--paper)', border: '1px solid var(--line)', borderRadius: 14, padding: '11px 14px', boxShadow: 'var(--sh-card)' }}>
          <Icon name="search" size={19} color="var(--ink-3)" />
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="Search merchant or category" style={{ border: 'none', outline: 'none', background: 'transparent', flex: 1, fontFamily: 'var(--ui)', fontSize: 15, color: 'var(--ink)' }} />
          {q && <button onClick={() => setQ('')}><Icon name="close" size={17} color="var(--ink-3)" /></button>}
        </div>

        {/* filter chips */}
        <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
          {[['all', 'All'], ['expense', 'Expenses'], ['income', 'Income']].map(([k, l]) => (
            <Chip key={k} active={kind === k} onClick={() => setKind(k)}>{l}</Chip>
          ))}
        </div>

        {/* net for selection */}
        <div style={{ marginTop: 16, display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
          <span style={{ fontSize: 13, color: 'var(--ink-3)', fontWeight: 600 }}>{list.length} transactions</span>
          <span className="num" style={{ fontSize: 16, fontWeight: 700, color: total >= 0 ? 'var(--income)' : 'var(--ink)' }}>Net {fmt(total, { sign: true })}</span>
        </div>
      </div>

      {/* groups */}
      {list.length === 0 ? (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '40px 30px', textAlign: 'center' }}>
          <EmptyArt />
          <div style={{ fontSize: 18, fontWeight: 700, marginTop: 14, whiteSpace: 'nowrap' }}>Nothing here yet</div>
          <p style={{ fontSize: 14, color: 'var(--ink-2)', marginTop: 4, lineHeight: 1.45 }}>No matches for this filter. Snap a receipt to add your first one.</p>
          <button onClick={() => go('capture')} style={{ marginTop: 16, padding: '12px 22px', borderRadius: 14, background: 'var(--accent)', color: '#fff', fontWeight: 700, fontSize: 15, display: 'flex', alignItems: 'center', gap: 8, whiteSpace: 'nowrap' }}>
            <Icon name="camera" size={18} color="#fff" /> Snap a receipt
          </button>
        </div>
      ) : groups.map(g => (
        <div key={g.date} style={{ marginTop: 18 }}>
          <div style={{ padding: '0 20px 8px', fontSize: 13, fontWeight: 700, color: 'var(--ink-3)' }}>{dayLabel(g.date)}</div>
          <Card style={{ margin: '0 18px' }} pad="2px 14px">
            {g.items.map((t, i) => (
              <TxnRow key={t.id} t={t} last={i === g.items.length - 1} onClick={() => go('txn', t)} />
            ))}
          </Card>
        </div>
      ))}
    </div>
  );
}

// ── Detail view (full screen) ─────────────────────────────────
function detailRow(label, value, valueColor) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '14px 0', borderBottom: '1px solid var(--line-2)' }}>
      <span style={{ fontSize: 14, color: 'var(--ink-2)', fontWeight: 500 }}>{label}</span>
      <span style={{ fontSize: 14.5, fontWeight: 700, color: valueColor || 'var(--ink)' }}>{value}</span>
    </div>
  );
}

function TxnDetail({ t, onClose }) {
  const c = CATS[t.cat];
  const income = t.amount > 0;
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 70, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <div style={{ padding: '54px 18px 12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="arrowLeft" size={20} color="var(--ink-2)" />
        </button>
        <span style={{ fontSize: 16, fontWeight: 700 }}>Transaction</span>
        <button style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="dots" size={20} color="var(--ink-2)" />
        </button>
      </div>

      <div className="scroll" style={{ flex: 1, padding: '0 18px 110px' }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', padding: '8px 0 18px' }}>
          <IconCircle name={c.icon} tint={c.tint} soft={c.soft} size={62} isize={30} fill={t.cat === 'income'} />
          <div style={{ fontSize: 19, fontWeight: 700, marginTop: 12 }}>{t.merchant}</div>
          <div className="num" style={{ fontSize: 38, fontWeight: 700, marginTop: 2, color: income ? 'var(--income)' : 'var(--ink)' }}>{fmt(t.amount, { sign: true })}</div>
          <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
            <span style={{ fontSize: 12, fontWeight: 700, padding: '5px 11px', borderRadius: 999, background: t.mode === 'business' ? 'var(--b-soft)' : 'var(--p-soft)', color: t.mode === 'business' ? 'var(--b-deep)' : 'var(--p-deep)', textTransform: 'capitalize' }}>{t.mode}</span>
            {t.ai && <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 12, fontWeight: 700, padding: '5px 11px', borderRadius: 999, background: 'var(--paper)', border: '1px solid var(--line)', color: 'var(--accent)' }}><Icon name="sparkles" size={12} color="var(--accent)" fill /> AI sorted</span>}
          </div>
        </div>

        <Card pad="2px 16px">
          {detailRow('Category', c.label)}
          {detailRow('Date', fmtDate(t.date, { weekday: 'short', day: 'numeric', month: 'long', year: 'numeric' }))}
          {detailRow('Payment', t.method)}
          {t.gst != null && detailRow('GST included', fmt(t.gst))}
          {t.tax && detailRow('Tax note', t.tax)}
          {t.deductible != null && detailRow('Deductible', t.deductible + '%', 'var(--income)')}
        </Card>

        {!income && (
          <Card pad={16} style={{ marginTop: 14 }}>
            <div style={{ display: 'flex', gap: 12, alignItems: 'center' }}>
              <div style={{ width: 56, height: 74, borderRadius: 10, overflow: 'hidden', flexShrink: 0, background: '#fff', boxShadow: 'var(--sh-card)' }}>
                <div style={{ transform: 'scale(.3)', transformOrigin: 'top left', width: 188 }}><ReceiptPaper /></div>
              </div>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 14, fontWeight: 700 }}>Receipt attached</div>
                <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 2 }}>Tap to view full image</div>
              </div>
              <Icon name="chevR" size={18} color="var(--ink-3)" />
            </div>
          </Card>
        )}

        <div style={{ display: 'flex', gap: 10, marginTop: 16 }}>
          <button style={{ flex: 1, height: 50, borderRadius: 15, background: 'var(--paper)', border: '1px solid var(--line)', fontWeight: 700, fontSize: 14.5, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7 }}>
            <Icon name="pencil" size={18} color="var(--ink-2)" /> Edit
          </button>
          <button style={{ flex: 1, height: 50, borderRadius: 15, background: 'var(--paper)', border: '1px solid var(--line)', fontWeight: 700, fontSize: 14.5, color: 'var(--alert)', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7 }}>
            <Icon name="trash" size={18} color="var(--alert)" /> Delete
          </button>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { TransactionsScreen, TxnDetail });
