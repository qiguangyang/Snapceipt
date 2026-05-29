// settings-pages.jsx — Profile detail, Categories & rules, Tax & GST, Connected banks
const { useState: useStateS } = React;

function PageHeader({ title, onClose, trailing }) {
  return (
    <div style={{ padding: '54px 18px 12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
      <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
        <Icon name="arrowLeft" size={20} color="var(--ink-2)" />
      </button>
      <span style={{ fontSize: 16, fontWeight: 700, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis', flex: 1, textAlign: 'center', minWidth: 0, padding: '0 6px' }}>{title}</span>
      <div style={{ width: 40, flexShrink: 0, display: 'flex', justifyContent: 'flex-end' }}>{trailing}</div>
    </div>
  );
}

function GroupLabel({ children }) {
  return <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, margin: '20px 2px 10px', textTransform: 'uppercase', letterSpacing: 0.3 }}>{children}</div>;
}

function Row({ label, value, valueColor, last, onClick, chevron }) {
  return (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, padding: '14px 0', borderBottom: last ? 'none' : '1px solid var(--line-2)', cursor: onClick ? 'pointer' : 'default' }}>
      <span style={{ fontSize: 14.5, color: 'var(--ink-2)', fontWeight: 500, whiteSpace: 'nowrap' }}>{label}</span>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span style={{ fontSize: 14.5, fontWeight: 700, color: valueColor || 'var(--ink)', whiteSpace: 'nowrap' }}>{value}</span>
        {chevron && <Icon name="chevR" size={16} color="var(--ink-3)" />}
      </div>
    </div>
  );
}

function MiniSwitch({ on, onToggle }) {
  return (
    <button onClick={onToggle} style={{ width: 46, height: 28, borderRadius: 999, background: on ? 'var(--income)' : 'var(--line)', position: 'relative', transition: 'background .2s', flexShrink: 0 }}>
      <div style={{ position: 'absolute', top: 3, left: on ? 21 : 3, width: 22, height: 22, borderRadius: 999, background: '#fff', transition: 'left .2s', boxShadow: '0 1px 3px rgba(0,0,0,.2)' }} />
    </button>
  );
}

// ── Profile detail ────────────────────────────────────────────
function ProfileDetailScreen({ profile, isActive, onMakeActive, onClose }) {
  const p = profile || { name: 'Profile', type: 'personal', initials: 'P', palette: ['var(--accent)', 'var(--accent-soft)', 'var(--accent-deep)'] };
  const pal = p.palette;
  const biz = p.type === 'business';
  const [gst, setGst] = useStateS(biz);
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 72, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <PageHeader title="Profile" onClose={onClose} trailing={<button style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon name="pencil" size={18} color="var(--ink-2)" /></button>} />
      <div className="scroll" style={{ flex: 1, padding: '4px 18px 40px' }}>
        {/* hero */}
        <div style={{ borderRadius: 'var(--r-card)', padding: 20, color: '#fff', position: 'relative', overflow: 'hidden', background: 'linear-gradient(150deg,' + pal[0] + ',' + pal[2] + ')', boxShadow: '0 16px 32px -18px ' + pal[0] }}>
          <div style={{ position: 'absolute', right: -26, top: -26, width: 120, height: 120, borderRadius: 999, background: 'rgba(255,255,255,.1)' }} />
          <div style={{ display: 'flex', alignItems: 'center', gap: 14, position: 'relative' }}>
            <div style={{ width: 56, height: 56, borderRadius: 18, background: 'rgba(255,255,255,.22)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 22 }}>{p.initials}</div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 21, fontWeight: 700, letterSpacing: -0.4, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{p.name}</div>
              <div style={{ fontSize: 13, opacity: .85, marginTop: 2, textTransform: 'capitalize' }}>{p.type} profile</div>
            </div>
          </div>
          {isActive ? (
            <div style={{ marginTop: 16, display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 12.5, fontWeight: 700, background: 'rgba(255,255,255,.2)', padding: '6px 12px', borderRadius: 999, position: 'relative' }}>
              <Icon name="check" size={14} color="#fff" sw={2.8} /> Currently active
            </div>
          ) : (
            <button onClick={onMakeActive} style={{ marginTop: 16, width: '100%', padding: '13px', borderRadius: 14, background: 'rgba(255,255,255,.92)', color: pal[2], fontSize: 15, fontWeight: 700, position: 'relative', whiteSpace: 'nowrap' }}>
              Switch to this profile
            </button>
          )}
        </div>

        <GroupLabel>Details</GroupLabel>
        <Card pad="2px 16px">
          <Row label="Profile name" value={p.name} chevron onClick={() => {}} />
          <Row label="Type" value={biz ? 'Business' : 'Personal'} />
          {biz && <Row label="ABN" value="12 345 678 901" />}
          {biz && (
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 0', borderBottom: '1px solid var(--line-2)' }}>
              <span style={{ fontSize: 14.5, color: 'var(--ink-2)', fontWeight: 500, whiteSpace: 'nowrap' }}>Registered for GST</span>
              <MiniSwitch on={gst} onToggle={() => setGst(!gst)} />
            </div>
          )}
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '14px 0' }}>
            <span style={{ fontSize: 14.5, color: 'var(--ink-2)', fontWeight: 500, whiteSpace: 'nowrap' }}>Accent colour</span>
            <div style={{ display: 'flex', gap: 7 }}>
              <div style={{ width: 26, height: 26, borderRadius: 9, background: 'linear-gradient(150deg,' + pal[0] + ',' + pal[2] + ')', boxShadow: '0 0 0 2px var(--cream), 0 0 0 4px ' + pal[0] }} />
            </div>
          </div>
        </Card>

        <GroupLabel>This profile</GroupLabel>
        <div style={{ display: 'flex', gap: 10 }}>
          <Card pad={14} style={{ flex: 1 }}>
            <Icon name="receipt" size={20} color={pal[0]} />
            <div className="num" style={{ fontSize: 22, fontWeight: 700, marginTop: 8 }}>{biz ? 41 : 7}</div>
            <div style={{ fontSize: 12, color: 'var(--ink-3)', fontWeight: 600 }}>Receipts</div>
          </Card>
          <Card pad={14} style={{ flex: 1 }}>
            <Icon name={biz ? 'shield' : 'wallet'} size={20} color="var(--income)" />
            <div className="num" style={{ fontSize: 22, fontWeight: 700, marginTop: 8 }}>{biz ? '$1.2k' : '$301'}</div>
            <div style={{ fontSize: 12, color: 'var(--ink-3)', fontWeight: 600 }}>{biz ? 'Deductible YTD' : 'Spent in May'}</div>
          </Card>
        </div>

        <GroupLabel>Manage</GroupLabel>
        <Card pad="2px 16px">
          <button style={{ display: 'flex', alignItems: 'center', gap: 12, width: '100%', padding: '13px 0', borderBottom: '1px solid var(--line-2)', textAlign: 'left' }}>
            <Icon name="download" size={19} color="var(--ink-2)" /><span style={{ fontSize: 14.5, fontWeight: 600, whiteSpace: 'nowrap' }}>Export this profile</span>
          </button>
          <button style={{ display: 'flex', alignItems: 'center', gap: 12, width: '100%', padding: '13px 0', textAlign: 'left', color: 'var(--alert)' }}>
            <Icon name="trash" size={19} color="var(--alert)" /><span style={{ fontSize: 14.5, fontWeight: 600, whiteSpace: 'nowrap' }}>Delete profile</span>
          </button>
        </Card>
      </div>
    </div>
  );
}

// ── Categories & rules ────────────────────────────────────────
const RULES = [
  { match: 'Uber, DiDi, Lyft', cat: 'fuel' },
  { match: 'Adobe, Figma, Apple', cat: 'software', note: '100% deductible' },
  { match: 'Cafés & restaurants', cat: 'meals', note: 'Meals · 50%' },
  { match: 'Woolworths, Coles', cat: 'groceries' },
];

function CategoriesScreen({ onClose }) {
  const keys = Object.keys(CATS).filter(k => k !== 'income');
  const counts = { meals: 12, groceries: 6, fuel: 9, software: 7, office: 4, home: 3, health: 2, travel: 5 };
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 72, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <PageHeader title="Categories & rules" onClose={onClose} trailing={<button style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--accent)', display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: '0 6px 14px -6px var(--accent)' }}><Icon name="plus" size={20} color="#fff" sw={2.3} /></button>} />
      <div className="scroll" style={{ flex: 1, padding: '4px 18px 40px' }}>
        {/* AI rules */}
        <div style={{ borderRadius: 'var(--r-inner)', padding: 14, background: 'linear-gradient(135deg, var(--accent-soft), #fff)', border: '1px solid var(--accent)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <Icon name="sparkles" size={18} color="var(--accent)" fill />
            <span style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--accent-deep)', whiteSpace: 'nowrap' }}>Smart rules</span>
            <span style={{ marginLeft: 'auto', fontSize: 11.5, fontWeight: 700, color: 'var(--accent-deep)', whiteSpace: 'nowrap' }}>{RULES.length} active</span>
          </div>
          <p style={{ margin: '7px 0 0', fontSize: 12.5, color: 'var(--ink-2)', lineHeight: 1.4 }}>Snapceipt auto-files receipts that match these rules.</p>
        </div>
        <Card style={{ marginTop: 12 }} pad="2px 16px">
          {RULES.map((r, i) => {
            const c = CATS[r.cat];
            return (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 0', borderBottom: i === RULES.length - 1 ? 'none' : '1px solid var(--line-2)' }}>
                <IconCircle name={c.icon} tint={c.tint} soft={c.soft} size={36} isize={18} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 13, color: 'var(--ink-3)', fontWeight: 600 }}>If contains</div>
                  <div style={{ fontSize: 14, fontWeight: 700, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{r.match}</div>
                </div>
                <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 2, flexShrink: 0 }}>
                  <span style={{ fontSize: 12.5, fontWeight: 700, color: c.tint, whiteSpace: 'nowrap' }}>→ {c.label}</span>
                  {r.note && <span style={{ fontSize: 11, color: 'var(--income)', fontWeight: 600, whiteSpace: 'nowrap' }}>{r.note}</span>}
                </div>
              </div>
            );
          })}
        </Card>

        <GroupLabel>Categories · {keys.length + 1}</GroupLabel>
        <Card pad="2px 16px">
          {keys.map((k, i) => {
            const c = CATS[k];
            return (
              <div key={k} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 0', borderBottom: i === keys.length - 1 ? 'none' : '1px solid var(--line-2)' }}>
                <IconCircle name={c.icon} tint={c.tint} soft={c.soft} size={36} isize={18} />
                <span style={{ flex: 1, fontSize: 14.5, fontWeight: 600 }}>{c.label}</span>
                <span className="num" style={{ fontSize: 13, color: 'var(--ink-3)', fontWeight: 600 }}>{counts[k] || 0}</span>
                <Icon name="chevR" size={16} color="var(--ink-3)" />
              </div>
            );
          })}
        </Card>
        <button style={{ width: '100%', marginTop: 12, padding: '13px', borderRadius: 14, background: 'var(--paper)', border: '1px dashed var(--line)', color: 'var(--ink-2)', fontWeight: 700, fontSize: 14, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, whiteSpace: 'nowrap' }}>
          <Icon name="plus" size={18} color="var(--ink-2)" /> New category
        </button>
      </div>
    </div>
  );
}

// ── Tax & GST ─────────────────────────────────────────────────
function TaxScreen({ onClose }) {
  const [gst, setGst] = useStateS(true);
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 72, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <PageHeader title="Tax & GST settings" onClose={onClose} />
      <div className="scroll" style={{ flex: 1, padding: '4px 18px 40px' }}>
        {/* summary */}
        <div style={{ display: 'flex', gap: 10 }}>
          <Card pad={14} style={{ flex: 1 }}>
            <Icon name="shield" size={20} color="var(--income)" />
            <div className="num" style={{ fontSize: 21, fontWeight: 700, marginTop: 8 }}>$1,287</div>
            <div style={{ fontSize: 11.5, color: 'var(--ink-3)', fontWeight: 600 }}>Deductible YTD</div>
          </Card>
          <Card pad={14} style={{ flex: 1 }}>
            <Icon name="receipt" size={20} color="var(--accent)" />
            <div className="num" style={{ fontSize: 21, fontWeight: 700, marginTop: 8 }}>$214</div>
            <div style={{ fontSize: 11.5, color: 'var(--ink-3)', fontWeight: 600 }}>GST on purchases</div>
          </Card>
        </div>

        <GroupLabel>Business</GroupLabel>
        <Card pad="2px 16px">
          <Row label="ABN" value="12 345 678 901" />
          <Row label="Entity type" value="Sole trader" chevron onClick={() => {}} />
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 0', borderBottom: '1px solid var(--line-2)' }}>
            <span style={{ fontSize: 14.5, color: 'var(--ink-2)', fontWeight: 500, whiteSpace: 'nowrap' }}>Registered for GST</span>
            <MiniSwitch on={gst} onToggle={() => setGst(!gst)} />
          </div>
          <Row label="GST accounting" value="Cash" chevron onClick={() => {}} last />
        </Card>

        <GroupLabel>Financial year</GroupLabel>
        <Card pad="2px 16px">
          <Row label="Tax year" value="FY 2025–26" chevron onClick={() => {}} />
          <Row label="BAS period" value="Quarterly" chevron onClick={() => {}} />
          <Row label="Next BAS due" value="28 Jul 2026" valueColor="var(--accent)" last />
        </Card>

        <GroupLabel>Deduction defaults</GroupLabel>
        <Card pad="2px 16px">
          <Row label="Meals & entertainment" value="50%" />
          <Row label="Vehicle method" value="Logbook" chevron onClick={() => {}} />
          <Row label="Home office" value="67c / hour" chevron onClick={() => {}} last />
        </Card>

        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', marginTop: 16, padding: 14, borderRadius: 'var(--r-inner)', background: 'var(--paper-2)' }}>
          <Icon name="info" size={18} color="var(--ink-3)" style={{ marginTop: 1 }} />
          <p style={{ margin: 0, fontSize: 12.5, color: 'var(--ink-2)', lineHeight: 1.45 }}>These defaults pre-fill the deductible % when AI sorts a receipt. You can always override per receipt.</p>
        </div>
      </div>
    </div>
  );
}

// ── Connected banks ───────────────────────────────────────────
const BANKS = [
  { name: 'CBA — Everyday', acct: '•••• 2241', initials: 'CB', tint: '#E8B400', soft: '#FBF1CC', sync: 'Synced 2h ago', auto: true },
  { name: 'Amex — Business', acct: '•••• 1009', initials: 'AX', tint: '#2F6FB0', soft: '#E2ECF6', sync: 'Synced 5h ago', auto: true },
];

function ConnectedBanksScreen({ onClose }) {
  const [autos, setAutos] = useStateS(BANKS.map(b => b.auto));
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 72, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <PageHeader title="Connected banks" onClose={onClose} />
      <div className="scroll" style={{ flex: 1, padding: '4px 18px 40px' }}>
        {/* reconcile banner */}
        <div style={{ borderRadius: 'var(--r-inner)', padding: 14, background: 'var(--income-soft)', display: 'flex', alignItems: 'center', gap: 11 }}>
          <div style={{ width: 38, height: 38, borderRadius: 12, background: 'var(--income)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}><Icon name="swap" size={20} color="#fff" /></div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 14, fontWeight: 700 }}>12 receipts matched this week</div>
            <div style={{ fontSize: 12.5, color: 'var(--ink-2)', marginTop: 1 }}>Bank lines auto-reconciled to receipts.</div>
          </div>
        </div>

        <GroupLabel>Linked accounts</GroupLabel>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {BANKS.map((b, i) => (
            <Card key={i} pad={16}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ width: 44, height: 44, borderRadius: 13, background: b.soft, display: 'flex', alignItems: 'center', justifyContent: 'center', color: b.tint, fontFamily: 'var(--display)', fontWeight: 700, fontSize: 15, flexShrink: 0 }}>{b.initials}</div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontSize: 15, fontWeight: 700, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{b.name}</div>
                  <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1 }}>{b.acct}</div>
                </div>
                <button style={{ padding: 6 }}><Icon name="dots" size={20} color="var(--ink-3)" /></button>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--line-2)' }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12.5, color: 'var(--income)', fontWeight: 600, whiteSpace: 'nowrap' }}>
                  <span style={{ width: 7, height: 7, borderRadius: 999, background: 'var(--income)' }} /> {b.sync}
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontSize: 12.5, color: 'var(--ink-2)', fontWeight: 600, whiteSpace: 'nowrap' }}>Auto-import</span>
                  <MiniSwitch on={autos[i]} onToggle={() => setAutos(a => a.map((x, j) => j === i ? !x : x))} />
                </div>
              </div>
            </Card>
          ))}
        </div>

        <button style={{ width: '100%', marginTop: 12, padding: '14px', borderRadius: 14, background: 'var(--paper)', border: '1px dashed var(--line)', color: 'var(--ink-2)', fontWeight: 700, fontSize: 14.5, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, whiteSpace: 'nowrap' }}>
          <Icon name="plus" size={18} color="var(--ink-2)" /> Connect a bank
        </button>

        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', marginTop: 16, padding: 14, borderRadius: 'var(--r-inner)', background: 'var(--paper-2)' }}>
          <Icon name="lock" size={18} color="var(--ink-3)" style={{ marginTop: 1 }} />
          <p style={{ margin: 0, fontSize: 12.5, color: 'var(--ink-2)', lineHeight: 1.45 }}>Connections are read-only and bank-grade encrypted. Snapceipt can never move your money.</p>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { ProfileDetailScreen, CategoriesScreen, TaxScreen, ConnectedBanksScreen });
