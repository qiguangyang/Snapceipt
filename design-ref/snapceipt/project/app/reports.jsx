// reports.jsx — spend breakdown, trends, tax summary, export
const { useState: useStateR } = React;

const TREND = [
  { label: 'Jan', income: 4800, expense: 3100 },
  { label: 'Feb', income: 5200, expense: 2700 },
  { label: 'Mar', income: 4100, expense: 3600 },
  { label: 'Apr', income: 6050, expense: 2900 },
  { label: 'May', income: 5050, expense: 2480 },
];

function StatPill({ label, value, tint, icon }) {
  return (
    <Card pad={14} style={{ flex: 1 }}>
      <Icon name={icon} size={20} color={tint} />
      <div className="num" style={{ fontSize: 22, fontWeight: 700, marginTop: 8, letterSpacing: -0.5 }}>{value}</div>
      <div style={{ fontSize: 12, color: 'var(--ink-3)', fontWeight: 600, marginTop: 1 }}>{label}</div>
    </Card>
  );
}

function ReportsScreen({ txns, mode, go }) {
  const [period, setPeriod] = useStateR('month');

  const m = txns.filter(t => t.mode === mode);
  const expenses = m.filter(t => t.amount < 0);
  const income = m.filter(t => t.amount > 0).reduce((s, t) => s + t.amount, 0);
  const expTotal = expenses.reduce((s, t) => s - t.amount, 0);

  // category breakdown
  const byCat = {};
  expenses.forEach(t => { byCat[t.cat] = (byCat[t.cat] || 0) + (-t.amount); });
  const segs = Object.keys(byCat)
    .map(k => ({ key: k, value: byCat[k], tint: CATS[k].tint, label: CATS[k].label, icon: CATS[k].icon }))
    .sort((a, b) => b.value - a.value);

  const deductible = expenses.reduce((s, t) => s + (t.deductible ? (-t.amount) * t.deductible / 100 : 0), 0);
  const gst = expenses.reduce((s, t) => s + (t.gst || 0), 0);

  return (
    <div className="scroll" style={{ height: '100%', padding: '54px 18px 124px' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <h1 style={{ fontFamily: 'var(--display)', fontSize: 30, fontWeight: 700, letterSpacing: -0.6, margin: 0 }}>Reports</h1>
        <button onClick={() => go('export')} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '10px 14px', borderRadius: 12, background: 'var(--accent)', color: '#fff', fontWeight: 700, fontSize: 13.5, boxShadow: '0 8px 18px -8px var(--accent)' }}>
          <Icon name="share" size={17} color="#fff" /> Export
        </button>
      </div>

      <div style={{ marginTop: 14 }}>
        <Segmented value={period} onChange={setPeriod} options={[{ value: 'month', label: 'Month' }, { value: 'quarter', label: 'Quarter' }, { value: 'year', label: 'FY' }]} />
      </div>

      {/* income vs expense trend */}
      <Card style={{ marginTop: 16 }} pad={18}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div>
            <div style={{ fontSize: 13, color: 'var(--ink-3)', fontWeight: 600, whiteSpace: 'nowrap' }}>Net saved · last 5 months</div>
            <div className="num" style={{ fontSize: 28, fontWeight: 700, letterSpacing: -0.5, marginTop: 2 }}>{fmt(income - expTotal, { cents: false })}</div>
          </div>
          <div style={{ display: 'flex', gap: 12, fontSize: 11.5, fontWeight: 600 }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><span style={{ width: 9, height: 9, borderRadius: 3, background: 'var(--income)' }} /> In</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><span style={{ width: 9, height: 9, borderRadius: 3, background: 'var(--accent)' }} /> Out</span>
          </div>
        </div>
        <div style={{ marginTop: 16 }}><BarPair data={TREND} /></div>
      </Card>

      {/* donut category breakdown */}
      <Card style={{ marginTop: 14 }} pad={18}>
        <div style={{ fontSize: 15, fontWeight: 700, marginBottom: 4 }}>Where it went</div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 18, marginTop: 8 }}>
          <Donut segments={segs} size={140} thickness={20}>
            <div className="num" style={{ fontSize: 22, fontWeight: 700, letterSpacing: -0.5 }}>{fmtK(expTotal)}</div>
            <div style={{ fontSize: 11, color: 'var(--ink-3)', fontWeight: 600 }}>spent</div>
          </Donut>
          <div style={{ flex: 1 }}>
            {segs.slice(0, 5).map(s => (
              <div key={s.key} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 9 }}>
                <span style={{ width: 9, height: 9, borderRadius: 3, background: s.tint, flexShrink: 0 }} />
                <span style={{ fontSize: 12.5, fontWeight: 600, flex: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{s.label}</span>
                <span className="num" style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--ink-2)' }}>{fmtK(s.value)}</span>
              </div>
            ))}
          </div>
        </div>
      </Card>

      {mode === 'business' && (
        <>
          <div style={{ display: 'flex', gap: 10, marginTop: 14 }}>
            <StatPill label="Deductible YTD" value={fmtK(deductible)} tint="var(--income)" icon="shield" />
            <StatPill label="GST on purchases" value={fmtK(gst)} tint="var(--accent)" icon="receipt" />
          </div>

          {/* logbooks */}
          <div style={{ fontSize: 17, fontWeight: 700, letterSpacing: -0.3, margin: '20px 2px 10px' }}>Logbooks</div>
          <Card pad="2px 16px">
            {[
              { icon: 'car', tint: '#2F6FB0', soft: '#E2ECF6', label: 'Vehicle logbook', sub: '342 km · 12 trips this month', val: '$215', route: 'mileage' },
              { icon: 'wfh', tint: '#0E7C72', soft: '#DCF0ED', label: 'Working from home', sub: '68 hrs logged · fixed rate', val: '$45.56', route: 'wfh' },
            ].map((r, i, arr) => (
              <button key={r.label} onClick={() => go(r.route)} style={{ display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left', padding: '14px 0', borderBottom: i === arr.length - 1 ? 'none' : '1px solid var(--line-2)' }}>
                <IconCircle name={r.icon} tint={r.tint} soft={r.soft} />
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 14.5, fontWeight: 700 }}>{r.label}</div>
                  <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1 }}>{r.sub}</div>
                </div>
                <span className="num" style={{ fontSize: 14.5, fontWeight: 700, color: 'var(--income)' }}>{r.val}</span>
                <Icon name="chevR" size={17} color="var(--ink-3)" />
              </button>
            ))}
          </Card>
        </>
      )}

      {mode === 'personal' && (
        <Card style={{ marginTop: 14 }} pad={18}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <IconCircle name="star" tint="var(--accent)" size={40} isize={20} fill />
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14.5, fontWeight: 700 }}>You're under budget</div>
              <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1 }}>Spending is 18% lower than April. Nice work.</div>
            </div>
          </div>
        </Card>
      )}

      {/* AI insight */}
      <Card style={{ marginTop: 14, background: 'linear-gradient(135deg, var(--accent-soft), #fff)', border: '1px solid var(--accent)' }} pad={16}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <Icon name="sparkles" size={18} color="var(--accent)" fill />
          <span style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--accent-deep)' }}>Snapceipt insight</span>
        </div>
        <p style={{ margin: '8px 0 0', fontSize: 13.5, color: 'var(--ink-2)', lineHeight: 1.45 }}>
          {mode === 'business'
            ? 'Software is your fastest-growing category. 3 subscriptions renew next week — total $653.'
            : 'Groceries are trending down this month. At this rate you\'ll save ~$120 vs your budget.'}
        </p>
      </Card>
    </div>
  );
}

// Export sheet (bottom sheet)
function ExportSheet({ onClose }) {
  const [fmtSel, setFmt] = useStateR('pdf');
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 75, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
      <div onClick={onClose} style={{ position: 'absolute', inset: 0, background: 'rgba(20,16,12,.4)', animation: 'sc-fade .25s both' }} />
      <div style={{ position: 'relative', background: 'var(--cream)', borderRadius: '28px 28px 0 0', padding: '12px 18px 38px', animation: 'sc-rise .32s cubic-bezier(.22,.61,.36,1) both' }}>
        <div style={{ width: 40, height: 5, borderRadius: 999, background: 'var(--line)', margin: '0 auto 16px' }} />
        <div style={{ fontSize: 20, fontWeight: 700, fontFamily: 'var(--display)' }}>Export &amp; send</div>
        <p style={{ fontSize: 13.5, color: 'var(--ink-2)', margin: '4px 0 16px' }}>Tax-ready summary with all receipts attached.</p>

        <div style={{ display: 'flex', gap: 10 }}>
          {[['pdf', 'doc', 'PDF report'], ['csv', 'film', 'CSV file'], ['accountant', 'share', 'To accountant']].map(([k, ic, l]) => (
            <button key={k} onClick={() => setFmt(k)} style={{ flex: 1, padding: '16px 8px', borderRadius: 16, background: fmtSel === k ? 'var(--accent-soft)' : 'var(--paper)', border: '1px solid ' + (fmtSel === k ? 'var(--accent)' : 'var(--line)'), display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8 }}>
              <Icon name={ic} size={24} color={fmtSel === k ? 'var(--accent)' : 'var(--ink-2)'} />
              <span style={{ fontSize: 12.5, fontWeight: 700, color: fmtSel === k ? 'var(--accent-deep)' : 'var(--ink-2)' }}>{l}</span>
            </button>
          ))}
        </div>

        <Card style={{ marginTop: 14 }} pad="2px 16px">
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '13px 0', borderBottom: '1px solid var(--line-2)' }}>
            <span style={{ fontSize: 14, color: 'var(--ink-2)' }}>Period</span><span style={{ fontSize: 14, fontWeight: 700 }}>FY 2025–26</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '13px 0', borderBottom: '1px solid var(--line-2)' }}>
            <span style={{ fontSize: 14, color: 'var(--ink-2)' }}>Receipts included</span><span style={{ fontSize: 14, fontWeight: 700 }}>48 images</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '13px 0' }}>
            <span style={{ fontSize: 14, color: 'var(--ink-2)' }}>Deductible total</span><span className="num" style={{ fontSize: 14, fontWeight: 700, color: 'var(--income)' }}>$1,287.40</span>
          </div>
        </Card>

        <button onClick={onClose} style={{ width: '100%', height: 54, marginTop: 16, borderRadius: 17, background: 'var(--accent)', color: '#fff', fontSize: 16, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
          <Icon name="share" size={19} color="#fff" /> Generate &amp; send
        </button>
      </div>
    </div>
  );
}

Object.assign(window, { ReportsScreen, ExportSheet });
