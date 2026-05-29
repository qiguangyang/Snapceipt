// home.jsx — Dashboard / Home screen
const { useState: useStateH } = React;

function TopBar({ profile, profiles, onOpenPicker, onBell }) {
  const multi = profiles.length > 1;
  const pal = profile.palette || ['var(--accent)', 'var(--accent-soft)', 'var(--accent-deep)'];
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 2px 0' }}>
      <button onClick={multi ? onOpenPicker : undefined} style={{ display: 'flex', alignItems: 'center', gap: 12, textAlign: 'left', minWidth: 0, flex: 1, cursor: multi ? 'pointer' : 'default' }}>
        <div style={{
          width: 46, height: 46, borderRadius: 15, flexShrink: 0,
          background: 'linear-gradient(135deg, ' + pal[0] + ', ' + pal[2] + ')',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: '#fff', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 17,
          boxShadow: '0 6px 14px -6px ' + pal[0],
        }}>{profile.initials}</div>
        <div style={{ minWidth: 0, display: 'flex', flexDirection: 'column', gap: 1 }}>
          <div style={{ fontSize: 11.5, color: 'var(--ink-3)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: 0.4, whiteSpace: 'nowrap' }}>Active profile</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
            <span style={{ fontSize: 19, fontWeight: 700, letterSpacing: -0.3, lineHeight: 1.15, whiteSpace: 'nowrap' }}>{profile.name}</span>
            {multi && (
              <span style={{ width: 22, height: 22, borderRadius: 999, background: 'var(--paper-2)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                <Icon name="chevD" size={14} color="var(--ink-2)" sw={2.2} />
              </span>
            )}
          </div>
        </div>
      </button>
      <button onClick={onBell} style={{
        width: 44, height: 44, borderRadius: 14, background: 'var(--paper)', flexShrink: 0, marginLeft: 8,
        border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center',
        position: 'relative', boxShadow: 'var(--sh-card)',
      }}>
        <Icon name="bell" size={21} color="var(--ink-2)" />
        <span style={{ position: 'absolute', top: 11, right: 12, width: 8, height: 8, borderRadius: 999, background: 'var(--accent)', border: '2px solid var(--paper)' }} />
      </button>
    </div>
  );
}

function ProfileSwitcher({ profiles, activeId, setActive, go }) {
  const style = (window.__sc && window.__sc.multi) || 'scroll';
  const active = profiles.find(p => p.id === activeId) || profiles[0];
  const typeIcon = (p) => p.type === 'business' ? 'building' : 'wallet';

  // 1–2 profiles → classic segmented bar
  if (profiles.length <= 2) {
    const idx = Math.max(0, profiles.findIndex(p => p.id === activeId));
    return (
      <div style={{ position: 'relative', display: 'grid', gridTemplateColumns: `repeat(${profiles.length},1fr)`, background: 'var(--paper-2)', borderRadius: 999, padding: 4 }}>
        <div style={{ position: 'absolute', top: 4, bottom: 4, left: 4, width: `calc((100% - 8px) / ${profiles.length})`, transform: `translateX(${idx * 100}%)`, background: 'var(--paper)', borderRadius: 999, boxShadow: '0 2px 6px -2px rgba(33,28,24,.18)', transition: 'transform .28s cubic-bezier(.22,.61,.36,1)' }} />
        {profiles.map(p => {
          const on = p.id === activeId;
          return (
            <button key={p.id} onClick={() => setActive(p.id)} style={{ position: 'relative', zIndex: 1, padding: '9px 4px', fontSize: 14, fontWeight: 600, color: on ? 'var(--ink)' : 'var(--ink-3)', display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 6, whiteSpace: 'nowrap' }}>
              <Icon name={typeIcon(p)} size={16} color={on ? p.palette[0] : 'var(--ink-3)'} /> {p.name}
            </button>
          );
        })}
      </div>
    );
  }

  // 3+ profiles, "menu" → compact active pill + avatar stack, opens picker sheet
  if (style === 'menu') {
    return (
      <button onClick={() => go('profilePicker')} style={{ width: '100%', display: 'flex', alignItems: 'center', gap: 12, background: 'var(--paper)', border: '1px solid var(--line)', borderRadius: 16, padding: '9px 12px', boxShadow: 'var(--sh-card)' }}>
        <div style={{ width: 38, height: 38, borderRadius: 12, background: 'linear-gradient(135deg,' + active.palette[0] + ',' + active.palette[2] + ')', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 15, flexShrink: 0 }}>{active.initials}</div>
        <div style={{ flex: 1, textAlign: 'left', minWidth: 0 }}>
          <div style={{ fontSize: 15, fontWeight: 700, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{active.name}</div>
          <div style={{ fontSize: 12, color: 'var(--ink-3)', whiteSpace: 'nowrap' }}>Tap to switch · {profiles.length} profiles</div>
        </div>
        <div style={{ display: 'flex', flexShrink: 0 }}>
          {profiles.slice(0, 3).map((p, i) => (
            <div key={p.id} style={{ width: 22, height: 22, borderRadius: 999, background: 'linear-gradient(135deg,' + p.palette[0] + ',' + p.palette[2] + ')', marginLeft: i ? -8 : 0, border: '2px solid var(--paper)' }} />
          ))}
        </div>
        <Icon name="chevD" size={18} color="var(--ink-3)" />
      </button>
    );
  }

  // 3+ profiles, default "scroll" → horizontal pill bar with +
  return (
    <div style={{ display: 'flex', gap: 8, overflowX: 'auto', paddingBottom: 2 }}>
      {profiles.map(p => {
        const on = p.id === activeId;
        return (
          <button key={p.id} onClick={() => setActive(p.id)} style={{
            flex: '0 0 auto', display: 'flex', alignItems: 'center', gap: 7, padding: '9px 15px', borderRadius: 999, fontSize: 14, fontWeight: 700, whiteSpace: 'nowrap', transition: 'all .18s',
            background: on ? p.palette[0] : 'var(--paper)', color: on ? '#fff' : 'var(--ink-2)',
            border: '1px solid ' + (on ? p.palette[0] : 'var(--line)'), boxShadow: on ? '0 8px 16px -8px ' + p.palette[0] : 'none',
          }}>
            <Icon name={typeIcon(p)} size={16} color={on ? '#fff' : 'var(--ink-3)'} /> {p.name}
          </button>
        );
      })}
      <button onClick={() => go('addProfile')} style={{ flex: '0 0 auto', width: 40, height: 40, borderRadius: 999, background: 'var(--paper)', border: '1px dashed var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Icon name="plus" size={18} color="var(--ink-3)" />
      </button>
    </div>
  );
}

function ModeToggle({ mode, setMode, variant }) {
  const v = variant || (window.__sc && window.__sc.toggle) || 'segmented';
  const opts = [
    { value: 'personal', label: 'Personal', icon: 'wallet', tint: 'var(--p)', soft: 'var(--p-soft)' },
    { value: 'business', label: 'Business', icon: 'building', tint: 'var(--b)', soft: 'var(--b-soft)' },
  ];

  if (v === 'pills') {
    return (
      <div style={{ display: 'flex', gap: 8 }}>
        {opts.map(o => {
          const on = mode === o.value;
          return (
            <button key={o.value} onClick={() => setMode(o.value)} style={{
              flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7,
              padding: '12px 0', borderRadius: 999, fontSize: 14.5, fontWeight: 700, transition: 'all .2s',
              background: on ? o.tint : 'var(--paper)', color: on ? '#fff' : 'var(--ink-3)',
              border: '1px solid ' + (on ? o.tint : 'var(--line)'),
              boxShadow: on ? '0 8px 18px -8px ' + o.tint : 'none',
            }}>
              <Icon name={o.icon} size={17} color={on ? '#fff' : 'var(--ink-3)'} /> {o.label}
            </button>
          );
        })}
      </div>
    );
  }

  if (v === 'underline') {
    const idx = mode === 'business' ? 1 : 0;
    return (
      <div style={{ position: 'relative', display: 'flex', borderBottom: '1.5px solid var(--line)' }}>
        {opts.map(o => {
          const on = mode === o.value;
          return (
            <button key={o.value} onClick={() => setMode(o.value)} style={{
              flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7,
              padding: '4px 0 13px', fontSize: 15, fontWeight: 700, transition: 'color .2s',
              color: on ? o.tint : 'var(--ink-3)',
            }}>
              <Icon name={o.icon} size={17} color={on ? o.tint : 'var(--ink-3)'} /> {o.label}
            </button>
          );
        })}
        <div style={{ position: 'absolute', bottom: -1.5, left: 0, width: '50%', height: 3, borderRadius: 999, background: 'var(--accent)', transform: `translateX(${idx * 100}%)`, transition: 'transform .28s cubic-bezier(.22,.61,.36,1)' }} />
      </div>
    );
  }

  return (
    <Segmented
      value={mode}
      onChange={setMode}
      options={opts.map(o => ({ value: o.value, label: (<><Icon name={o.icon} size={16} color={mode === o.value ? o.tint : 'var(--ink-3)'} /> {o.label}</>) }))}
    />
  );
}

function SummaryCard({ income, expense, mode }) {
  const net = income - expense;
  return (
    <div style={{
      borderRadius: 'var(--r-card)', padding: '18px 18px 16px', color: '#fff',
      background: 'linear-gradient(150deg, var(--accent) 0%, var(--accent-deep) 100%)',
      boxShadow: '0 14px 30px -16px var(--accent)', position: 'relative', overflow: 'hidden',
    }}>
      <div style={{ position: 'absolute', right: -30, top: -30, width: 150, height: 150, borderRadius: 999, background: 'rgba(255,255,255,.08)' }} />
      <div style={{ position: 'absolute', right: 20, bottom: -50, width: 120, height: 120, borderRadius: 999, background: 'rgba(255,255,255,.06)' }} />
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', position: 'relative' }}>
        <span style={{ fontSize: 13, fontWeight: 600, opacity: .85, whiteSpace: 'nowrap' }}>Net this month · May</span>
        <span style={{ fontSize: 12, fontWeight: 700, background: 'rgba(255,255,255,.18)', padding: '4px 10px', borderRadius: 999, textTransform: 'capitalize' }}>{mode}</span>
      </div>
      <div className="num" style={{ fontSize: 40, fontWeight: 700, marginTop: 4, lineHeight: 1.05, position: 'relative' }}>
        {fmt(net, { cents: false })}
      </div>
      <div style={{ display: 'flex', gap: 10, marginTop: 16, position: 'relative' }}>
        <div style={{ flex: 1, background: 'rgba(255,255,255,.14)', borderRadius: 14, padding: '10px 12px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, opacity: .9, fontWeight: 600 }}>
            <Icon name="arrowDown" size={15} color="#fff" /> Income
          </div>
          <div className="num" style={{ fontSize: 18, fontWeight: 700, marginTop: 3 }}>{fmt(income, { cents: false })}</div>
        </div>
        <div style={{ flex: 1, background: 'rgba(255,255,255,.14)', borderRadius: 14, padding: '10px 12px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, opacity: .9, fontWeight: 600 }}>
            <Icon name="arrowUp" size={15} color="#fff" /> Expenses
          </div>
          <div className="num" style={{ fontSize: 18, fontWeight: 700, marginTop: 3 }}>{fmt(expense, { cents: false })}</div>
        </div>
      </div>
    </div>
  );
}

function SnapCTA({ onSnap, variant }) {
  const v = variant || (window.__sc && window.__sc.snap) || 'feature';

  if (v === 'gradient') {
    return (
      <button onClick={onSnap} style={{
        width: '100%', textAlign: 'left', borderRadius: 'var(--r-card)', padding: '16px 18px',
        display: 'flex', alignItems: 'center', gap: 14, position: 'relative', overflow: 'hidden',
        background: 'linear-gradient(135deg, var(--accent), var(--accent-deep))',
        boxShadow: '0 14px 28px -14px var(--accent)',
      }}>
        <div style={{ position: 'absolute', inset: 0, opacity: .2, backgroundImage: 'radial-gradient(circle at 80% 20%, #fff 1px, transparent 1.4px)', backgroundSize: '15px 15px' }} />
        <div style={{ width: 50, height: 50, borderRadius: 16, background: 'rgba(255,255,255,.22)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, position: 'relative' }}>
          <Icon name="camera" size={26} color="#fff" />
        </div>
        <div style={{ flex: 1, position: 'relative' }}>
          <div style={{ color: '#fff', fontSize: 18, fontWeight: 700, letterSpacing: -0.3 }}>Snap a receipt</div>
          <div style={{ color: 'rgba(255,255,255,.85)', fontSize: 13, marginTop: 1 }}>AI reads &amp; sorts it instantly</div>
        </div>
        <Icon name="arrowRight" size={22} color="#fff" />
      </button>
    );
  }

  if (v === 'tile') {
    return (
      <div style={{ display: 'flex', gap: 12 }}>
        <button onClick={onSnap} style={{ flex: 1, borderRadius: 'var(--r-card)', padding: 16, textAlign: 'left', background: 'linear-gradient(150deg, var(--accent), var(--accent-deep))', boxShadow: '0 12px 24px -14px var(--accent)' }}>
          <div style={{ width: 44, height: 44, borderRadius: 14, background: 'rgba(255,255,255,.22)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon name="camera" size={24} color="#fff" /></div>
          <div style={{ color: '#fff', fontSize: 15.5, fontWeight: 700, marginTop: 12 }}>Snap receipt</div>
          <div style={{ color: 'rgba(255,255,255,.8)', fontSize: 12, marginTop: 1 }}>Camera + AI</div>
        </button>
        <button onClick={onSnap} style={{ flex: 1, borderRadius: 'var(--r-card)', padding: 16, textAlign: 'left', background: 'var(--paper)', border: '1px solid var(--line)', boxShadow: 'var(--sh-card)' }}>
          <div style={{ width: 44, height: 44, borderRadius: 14, background: 'var(--accent-soft)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon name="plus" size={24} color="var(--accent)" /></div>
          <div style={{ fontSize: 15.5, fontWeight: 700, marginTop: 12 }}>Add manually</div>
          <div style={{ color: 'var(--ink-3)', fontSize: 12, marginTop: 1 }}>Type it in</div>
        </button>
      </div>
    );
  }

  // 'feature' (default)
  return (
    <button onClick={onSnap} style={{
      width: '100%', textAlign: 'left', borderRadius: 'var(--r-card)',
      padding: 0, overflow: 'hidden', display: 'flex', alignItems: 'stretch',
      background: 'var(--ink)', boxShadow: 'var(--sh-card)', position: 'relative',
    }}>
      <div style={{ padding: '18px 0 18px 18px', flex: 1 }}>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, background: 'rgba(255,255,255,.12)', padding: '4px 10px', borderRadius: 999, marginBottom: 10, whiteSpace: 'nowrap' }}>
          <Icon name="sparkles" size={14} color="var(--accent)" fill />
          <span style={{ fontSize: 11.5, fontWeight: 700, color: '#fff', letterSpacing: .2 }}>AI auto-sort</span>
        </div>
        <div style={{ color: '#fff', fontSize: 20, fontWeight: 700, letterSpacing: -0.3, lineHeight: 1.1 }}>Snap a receipt</div>
        <div style={{ color: 'rgba(255,255,255,.6)', fontSize: 13.5, marginTop: 3, maxWidth: 180 }}>We'll read the total, GST &amp; category for you.</div>
      </div>
      <div style={{ width: 116, position: 'relative', background: 'linear-gradient(150deg, var(--accent), var(--accent-deep))', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <div style={{ position: 'absolute', inset: 0, opacity: .25, backgroundImage: 'radial-gradient(circle at 70% 30%, #fff 1px, transparent 1.4px)', backgroundSize: '14px 14px' }} />
        <div style={{ width: 60, height: 60, borderRadius: 20, background: 'rgba(255,255,255,.22)', display: 'flex', alignItems: 'center', justifyContent: 'center', backdropFilter: 'blur(4px)' }}>
          <Icon name="camera" size={30} color="#fff" />
        </div>
      </div>
    </button>
  );
}

function QuickAction({ icon, label, tint, onClick }) {
  return (
    <button onClick={onClick} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 7 }}>
      <div style={{ width: 52, height: 52, borderRadius: 17, background: 'var(--paper)', border: '1px solid var(--line)', boxShadow: 'var(--sh-card)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Icon name={icon} size={23} color={tint || 'var(--accent)'} />
      </div>
      <span style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--ink-2)', textAlign: 'center', lineHeight: 1.15 }}>{label}</span>
    </button>
  );
}

function TxnRow({ t, onClick, last }) {
  const c = CATS[t.cat];
  const income = t.amount > 0;
  return (
    <button onClick={onClick} style={{
      display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left',
      padding: '12px 2px', borderBottom: last ? 'none' : '1px solid var(--line-2)',
    }}>
      <IconCircle name={c.icon} tint={c.tint} soft={c.soft} fill={t.cat === 'income'} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontSize: 14.5, fontWeight: 600, letterSpacing: -0.2, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{t.merchant}</div>
        <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1, display: 'flex', alignItems: 'center', gap: 6, whiteSpace: 'nowrap' }}>
          <span>{fmtDate(t.date)}</span>
          {t.ai && <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, color: 'var(--accent)', fontWeight: 600 }}><Icon name="sparkles" size={11} color="var(--accent)" fill /> AI</span>}
        </div>
      </div>
      <div className="num" style={{ fontSize: 15, fontWeight: 700, color: income ? 'var(--income)' : 'var(--ink)' }}>
        {fmt(t.amount, { sign: true })}
      </div>
    </button>
  );
}

function BudgetRow({ label, spent, cap, tint }) {
  const over = spent > cap;
  return (
    <div style={{ marginBottom: 14 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', marginBottom: 7 }}>
        <span style={{ fontSize: 13.5, fontWeight: 600, whiteSpace: 'nowrap' }}>{label}</span>
        <span className="num" style={{ fontSize: 12.5, color: over ? 'var(--alert)' : 'var(--ink-3)', fontWeight: 600, whiteSpace: 'nowrap' }}>
          {fmt(spent, { cents: false })} <span style={{ color: 'var(--ink-3)' }}>/ {fmt(cap, { cents: false })}</span>
        </span>
      </div>
      <Progress value={spent} max={cap} tint={over ? 'var(--alert)' : tint} />
    </div>
  );
}

function HomeScreen({ mode, setMode, txns, profile, go, snapVariant, profiles, activeId, setActive }) {
  const m = txns.filter(t => t.mode === mode);
  const income = m.filter(t => t.amount > 0).reduce((s, t) => s + t.amount, 0);
  const expense = m.filter(t => t.amount < 0).reduce((s, t) => s - t.amount, 0);
  const recent = m.slice(0, 4);

  return (
    <div className="scroll stagger" style={{ height: '100%', padding: '54px 18px 124px' }}>
      <div style={{ animationDelay: '0ms' }}><TopBar profile={profile} profiles={profiles} onOpenPicker={() => go('profilePicker')} onBell={() => go('alerts')} /></div>
      <div style={{ animationDelay: '80ms', marginTop: 16 }}><SummaryCard income={income} expense={expense} mode={mode} /></div>
      <div style={{ animationDelay: '120ms', marginTop: 14 }}><SnapCTA onSnap={() => go('capture')} variant={snapVariant} /></div>

      <div style={{ animationDelay: '160ms', marginTop: 18, display: 'flex', gap: 6 }}>
        {mode === 'business' ? (
          <>
            <QuickAction icon="doc" label="Create Quote" onClick={() => go('quote')} />
            <QuickAction icon="plus" label="Add Manually" onClick={() => go('manual')} />
            <QuickAction icon="chart" label="Reports" onClick={() => go('reports')} />
            <QuickAction icon="receipt" label="Receipts" onClick={() => go('txns')} />
          </>
        ) : (
          <>
            <QuickAction icon="star" label="Loyalty Card" onClick={() => go('loyalty')} />
            <QuickAction icon="plus" label="Add Manually" onClick={() => go('manual')} />
            <QuickAction icon="car" label="Mileage" onClick={() => go('mileage')} />
            <QuickAction icon="wfh" label="WFH log" onClick={() => go('wfh')} />
          </>
        )}
      </div>

      {mode === 'business' && (
        <Card style={{ marginTop: 18, animationDelay: '200ms' }} pad={16}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14, gap: 8 }}>
            <span style={{ fontSize: 15, fontWeight: 700, whiteSpace: 'nowrap' }}>Deductible · FY26</span>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 12, color: 'var(--income)', fontWeight: 700, background: 'var(--income-soft)', padding: '4px 9px', borderRadius: 999, flexShrink: 0 }}>
              <Icon name="shield" size={13} color="var(--income)" /> Tracked
            </span>
          </div>
          <BudgetRow label="Software & subscriptions" spent={576} cap={800} tint="#7B5BD6" />
          <BudgetRow label="Vehicle & travel" spent={735} cap={650} tint="var(--accent)" />
          <BudgetRow label="Meals (50% rule)" spent={142} cap={300} tint="var(--income)" />
        </Card>
      )}

      {mode === 'personal' && (
        <Card style={{ marginTop: 18, animationDelay: '200ms' }} pad={16}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
            <span style={{ fontSize: 15, fontWeight: 700 }}>Monthly budgets</span>
            <span style={{ fontSize: 12.5, color: 'var(--accent)', fontWeight: 600 }}>Edit</span>
          </div>
          <BudgetRow label="Groceries" spent={64.85} cap={600} tint="var(--accent)" />
          <BudgetRow label="Eating out" spent={18} cap={200} tint="var(--accent)" />
          <BudgetRow label="Utilities" spent={184.30} cap={250} tint="var(--accent)" />
        </Card>
      )}

      <div style={{ animationDelay: '240ms', marginTop: 20, display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '0 2px' }}>
        <span style={{ fontSize: 17, fontWeight: 700, letterSpacing: -0.3 }}>Recent activity</span>
        <button onClick={() => go('txns')} style={{ fontSize: 13, color: 'var(--accent)', fontWeight: 600, display: 'flex', alignItems: 'center', gap: 2 }}>
          See all <Icon name="chevR" size={15} color="var(--accent)" />
        </button>
      </div>
      <Card style={{ animationDelay: '280ms', marginTop: 10 }} pad="2px 14px">
        {recent.map((t, i) => (
          <TxnRow key={t.id} t={t} last={i === recent.length - 1} onClick={() => go('txn', t)} />
        ))}
      </Card>
    </div>
  );
}

Object.assign(window, { HomeScreen, TxnRow, ModeToggle, ProfileSwitcher });
