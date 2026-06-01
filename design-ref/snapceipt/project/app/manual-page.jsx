// manual-page.jsx — Add transaction manually (no camera)
const { useState: useStateM } = React;

function AddManualScreen({ mode, onClose, onSave }) {
  const [kind, setKind] = useStateM('expense');
  const [cents, setCents] = useStateM(0);
  const [cat, setCat] = useStateM('meals');
  const [merchant, setMerchant] = useStateM('');
  const [done, setDone] = useStateM(false);

  const isInc = kind === 'income';
  const amount = cents / 100;
  const catKeys = isInc ? ['income'] : Object.keys(CATS).filter(k => k !== 'income');
  const activeCat = isInc ? 'income' : cat;
  const c = CATS[activeCat];
  const tint = isInc ? 'var(--income)' : 'var(--accent)';

  const press = (d) => setCents(v => Math.min(v * 10 + d, 9999999));
  const dbl = () => setCents(v => Math.min(v * 100, 9999999));
  const back = () => setCents(v => Math.floor(v / 10));

  const save = () => {
    onSave({
      merchant: merchant.trim() || (isInc ? 'Income' : c.label),
      cat: activeCat, amount: isInc ? amount : -amount,
      date: '2026-05-30', mode, ai: false, method: 'Manual entry',
      gst: isInc ? undefined : +(amount - amount / 1.1).toFixed(2),
    });
    setDone(true);
  };

  if (done) {
    return (
      <div style={{ position: 'absolute', inset: 0, zIndex: 78, background: 'var(--cream)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 30 }}>
        <div style={{ position: 'relative', width: 104, height: 104, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ position: 'absolute', inset: 0, borderRadius: 999, background: tint, animation: 'sc-ring 1.1s ease-out .1s' }} />
          <div style={{ width: 92, height: 92, borderRadius: 28, background: tint, display: 'flex', alignItems: 'center', justifyContent: 'center', animation: 'sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both', boxShadow: '0 14px 30px -10px ' + tint }}>
            <svg width="50" height="50" viewBox="0 0 24 24" fill="none"><path d="M5 12.5 10 17.5 19.5 7" stroke="#fff" strokeWidth="2.8" strokeLinecap="round" strokeLinejoin="round" strokeDasharray="48" style={{ animation: 'sc-check .5s .35s ease-out both' }} /></svg>
          </div>
        </div>
        <div style={{ fontSize: 23, fontWeight: 700, fontFamily: 'var(--display)', marginTop: 24, animation: 'sc-fade-up .4s .35s both' }}>{isInc ? 'Income' : 'Expense'} added!</div>
        <p style={{ fontSize: 14.5, color: 'var(--ink-2)', textAlign: 'center', marginTop: 6, lineHeight: 1.45, animation: 'sc-fade-up .4s .45s both' }}>
          <strong className="num" style={{ color: 'var(--ink)' }}>{fmt(amount)}</strong> saved to <strong style={{ color: 'var(--ink)', textTransform: 'capitalize' }}>{mode}</strong>.
        </p>
        <button onClick={onClose} style={{ marginTop: 28, width: '100%', height: 54, borderRadius: 17, background: tint, color: '#fff', fontSize: 16, fontWeight: 700, animation: 'sc-fade-up .4s .55s both' }}>Done</button>
      </div>
    );
  }

  const Key = ({ label, onClick, sub }) => (
    <button onClick={onClick} style={{ flex: 1, height: 56, borderRadius: 16, background: 'var(--paper)', border: '1px solid var(--line)', boxShadow: 'var(--sh-card)', fontFamily: 'var(--display)', fontSize: 24, fontWeight: 600, color: 'var(--ink)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{label}</button>
  );

  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 72, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      {/* header */}
      <div style={{ padding: '54px 18px 8px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <Icon name="close" size={20} color="var(--ink-2)" />
        </button>
        <span style={{ fontSize: 16, fontWeight: 700, flex: 1, textAlign: 'center', whiteSpace: 'nowrap' }}>Add manually</span>
        <div style={{ width: 40, flexShrink: 0 }} />
      </div>

      <div style={{ padding: '0 18px', flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0 }}>
        {/* type toggle */}
        <Segmented value={kind} onChange={setKind} tint={tint}
          options={[{ value: 'expense', label: 'Expense' }, { value: 'income', label: 'Income' }]} />

        {/* amount */}
        <div style={{ textAlign: 'center', padding: '22px 0 14px' }}>
          <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: 0.4 }}>Amount</div>
          <div className="num" style={{ fontSize: 52, fontWeight: 700, letterSpacing: -1, color: cents ? tint : 'var(--ink-3)', marginTop: 4, lineHeight: 1 }}>{fmt(amount)}</div>
        </div>

        {/* category chips */}
        <div style={{ display: 'flex', gap: 8, overflowX: 'auto', paddingBottom: 4 }}>
          {catKeys.map(k => {
            const cc = CATS[k];
            const on = k === activeCat;
            return (
              <button key={k} onClick={() => setCat(k)} disabled={isInc} style={{ flex: '0 0 auto', display: 'flex', alignItems: 'center', gap: 7, padding: '8px 13px', borderRadius: 999, fontSize: 13, fontWeight: 700, whiteSpace: 'nowrap', background: on ? cc.soft : 'var(--paper)', color: on ? cc.tint : 'var(--ink-2)', border: '1px solid ' + (on ? cc.tint : 'var(--line)') }}>
                <Icon name={cc.icon} size={15} color={on ? cc.tint : 'var(--ink-3)'} fill={k === 'income'} /> {cc.label}
              </button>
            );
          })}
        </div>

        {/* merchant + date */}
        <Card style={{ marginTop: 12 }} pad="2px 14px">
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '12px 0', borderBottom: '1px solid var(--line-2)' }}>
            <Icon name={isInc ? 'wallet' : 'tag'} size={19} color="var(--ink-3)" />
            <input value={merchant} onChange={e => setMerchant(e.target.value)} placeholder={isInc ? 'Source (e.g. Invoice #1043)' : 'Merchant (e.g. Officeworks)'} style={{ flex: 1, border: 'none', outline: 'none', background: 'transparent', fontFamily: 'var(--ui)', fontSize: 15, fontWeight: 600, color: 'var(--ink)' }} />
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '12px 0' }}>
            <Icon name="calendar" size={19} color="var(--ink-3)" />
            <span style={{ flex: 1, fontSize: 15, fontWeight: 600 }}>Today · 30 May 2026</span>
            <Icon name="chevR" size={16} color="var(--ink-3)" />
          </div>
        </Card>

        <div style={{ flex: 1, minHeight: 8 }} />

        {/* keypad */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {[[1, 2, 3], [4, 5, 6], [7, 8, 9]].map((row, i) => (
            <div key={i} style={{ display: 'flex', gap: 8 }}>
              {row.map(d => <Key key={d} label={d} onClick={() => press(d)} />)}
            </div>
          ))}
          <div style={{ display: 'flex', gap: 8 }}>
            <Key label="00" onClick={dbl} />
            <Key label="0" onClick={() => press(0)} />
            <button onClick={back} style={{ flex: 1, height: 56, borderRadius: 16, background: 'var(--paper)', border: '1px solid var(--line)', boxShadow: 'var(--sh-card)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
              <Icon name="close" size={22} color="var(--ink-2)" />
            </button>
          </div>
        </div>
      </div>

      {/* save */}
      <div style={{ padding: '12px 18px 30px' }}>
        <button disabled={!cents} onClick={save} style={{ width: '100%', height: 56, borderRadius: 18, fontSize: 17, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, background: cents ? tint : 'var(--line)', color: cents ? '#fff' : 'var(--ink-3)', boxShadow: cents ? '0 12px 24px -10px ' + tint : 'none', transition: 'all .2s', whiteSpace: 'nowrap' }}>
          <Icon name="check" size={20} color={cents ? '#fff' : 'var(--ink-3)'} sw={2.6} /> Save {isInc ? 'income' : 'expense'}
        </button>
      </div>
    </div>
  );
}

Object.assign(window, { AddManualScreen });
