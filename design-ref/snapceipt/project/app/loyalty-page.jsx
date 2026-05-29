// loyalty-page.jsx — Loyalty / rewards card wallet
const CARDS = [
  { brand: 'Everyday Rewards', sub: 'Woolworths', num: '9 3517 2204 1183', pts: '2,140 pts', c1: '#1A8A3C', c2: '#0C5C26' },
  { brand: 'flybuys', sub: 'Coles Group', num: '6 0084 1029 5567', pts: '8,905 pts', c1: '#1457C7', c2: '#0A2F86' },
  { brand: 'MYER one', sub: 'Myer', num: '7 0119 8842 0031', pts: '1,260 credits', c1: '#2C2C2C', c2: '#000000' },
  { brand: 'Sister Club', sub: 'Priceline', num: '8 8021 5563 7790', pts: '$12 rewards', c1: '#D8467F', c2: '#A82C5E' },
];

function LoyaltyCard({ card, onClick }) {
  return (
    <button onClick={onClick} style={{ display: 'block', width: '100%', textAlign: 'left', border: 'none', borderRadius: 18, padding: 16, color: '#fff', position: 'relative', overflow: 'hidden', background: 'linear-gradient(145deg, ' + card.c1 + ', ' + card.c2 + ')', boxShadow: '0 12px 26px -14px ' + card.c1 }}>
      <div style={{ position: 'absolute', right: -28, top: -28, width: 110, height: 110, borderRadius: 999, background: 'rgba(255,255,255,.08)' }} />
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', position: 'relative' }}>
        <div>
          <div style={{ fontSize: 17, fontWeight: 700, fontFamily: 'var(--display)', letterSpacing: -0.2 }}>{card.brand}</div>
          <div style={{ fontSize: 12, opacity: .8, marginTop: 1, whiteSpace: 'nowrap' }}>{card.sub}</div>
        </div>
        <span style={{ fontSize: 11.5, fontWeight: 700, background: 'rgba(255,255,255,.2)', padding: '4px 10px', borderRadius: 999, whiteSpace: 'nowrap' }}>{card.pts}</span>
      </div>
      {/* barcode */}
      <div style={{ marginTop: 16, height: 40, borderRadius: 8, background: '#fff', padding: '7px 12px', display: 'flex', alignItems: 'center', position: 'relative' }}>
        <div style={{ flex: 1, height: '100%', backgroundImage: 'repeating-linear-gradient(90deg, #111 0 1.5px, transparent 1.5px 3px, #111 3px 5px, transparent 5px 8px, #111 8px 10px, transparent 10px 13px)' }} />
      </div>
      <div style={{ fontSize: 12.5, opacity: .9, marginTop: 8, fontVariantNumeric: 'tabular-nums', letterSpacing: 1, position: 'relative' }}>{card.num}</div>
    </button>
  );
}

function LoyaltyScreen({ onClose, onAdd, onOpen }) {
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 72, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <div style={{ padding: '54px 18px 12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <Icon name="arrowLeft" size={20} color="var(--ink-2)" />
        </button>
        <span style={{ fontSize: 16, fontWeight: 700, flex: 1, textAlign: 'center', whiteSpace: 'nowrap' }}>Loyalty cards</span>
        <button onClick={onAdd} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--accent)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, boxShadow: '0 6px 14px -6px var(--accent)' }}>
          <Icon name="plus" size={20} color="#fff" sw={2.3} />
        </button>
      </div>
      <div className="scroll" style={{ flex: 1, padding: '4px 18px 40px' }}>
        <p style={{ fontSize: 13.5, color: 'var(--ink-2)', margin: '0 2px 14px', lineHeight: 1.45 }}>Tap a card to show its barcode at the checkout — no more digging through your wallet.</p>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {CARDS.map((c, i) => <LoyaltyCard key={i} card={c} onClick={() => onOpen(c)} />)}
        </div>
        <button onClick={onAdd} style={{ width: '100%', marginTop: 14, padding: '14px', borderRadius: 14, background: 'var(--paper)', border: '1px dashed var(--line)', color: 'var(--ink-2)', fontWeight: 700, fontSize: 14.5, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, whiteSpace: 'nowrap' }}>
          <Icon name="plus" size={18} color="var(--ink-2)" /> Add a card
        </button>
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', marginTop: 16, padding: 14, borderRadius: 'var(--r-inner)', background: 'var(--paper-2)' }}>
          <Icon name="sparkles" size={18} color="var(--accent)" fill style={{ marginTop: 1 }} />
          <p style={{ margin: 0, fontSize: 12.5, color: 'var(--ink-2)', lineHeight: 1.45 }}>We'll match loyalty points to your receipts automatically when you scan.</p>
        </div>
      </div>
    </div>
  );
}

const BRANDS = [
  { name: 'Everyday Rewards', i: 'ER', c: '#1A8A3C' },
  { name: 'flybuys', i: 'fb', c: '#1457C7' },
  { name: 'MYER one', i: 'M', c: '#111111' },
  { name: 'Sister Club', i: 'SC', c: '#D8467F' },
  { name: 'Qantas FF', i: 'Q', c: '#E40000' },
  { name: 'Velocity', i: 'V', c: '#7A1FA2' },
  { name: 'Kmart', i: 'K', c: '#E51937' },
  { name: 'BWS', i: 'B', c: '#0A7D3E' },
  { name: 'T2 Tea', i: 'T2', c: '#1A1A1A' },
];

function AddLoyaltyScreen({ onClose }) {
  const [sel, setSel] = React.useState(null);
  const [num, setNum] = React.useState('');
  const [done, setDone] = React.useState(false);

  if (done) {
    return (
      <div style={{ position: 'absolute', inset: 0, zIndex: 79, background: 'var(--cream)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 30 }}>
        <div style={{ position: 'relative', width: 104, height: 104, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ position: 'absolute', inset: 0, borderRadius: 999, background: 'var(--income)', animation: 'sc-ring 1.1s ease-out .1s' }} />
          <div style={{ width: 92, height: 92, borderRadius: 28, background: 'var(--income)', display: 'flex', alignItems: 'center', justifyContent: 'center', animation: 'sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both', boxShadow: '0 14px 30px -10px var(--income)' }}>
            <svg width="50" height="50" viewBox="0 0 24 24" fill="none"><path d="M5 12.5 10 17.5 19.5 7" stroke="#fff" strokeWidth="2.8" strokeLinecap="round" strokeLinejoin="round" strokeDasharray="48" style={{ animation: 'sc-check .5s .35s ease-out both' }} /></svg>
          </div>
        </div>
        <div style={{ fontSize: 23, fontWeight: 700, fontFamily: 'var(--display)', marginTop: 24, animation: 'sc-fade-up .4s .35s both' }}>Card added!</div>
        <p style={{ fontSize: 14.5, color: 'var(--ink-2)', textAlign: 'center', marginTop: 6, lineHeight: 1.45, animation: 'sc-fade-up .4s .45s both' }}>
          <strong style={{ color: 'var(--ink)' }}>{sel ? sel.name : 'Your card'}</strong> is now in your wallet.
        </p>
        <button onClick={onClose} style={{ marginTop: 28, width: '100%', height: 54, borderRadius: 17, background: 'var(--accent)', color: '#fff', fontSize: 16, fontWeight: 700, animation: 'sc-fade-up .4s .55s both' }}>Done</button>
      </div>
    );
  }

  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 73, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <div style={{ padding: '54px 18px 12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <Icon name="arrowLeft" size={20} color="var(--ink-2)" />
        </button>
        <span style={{ fontSize: 16, fontWeight: 700, flex: 1, textAlign: 'center', whiteSpace: 'nowrap' }}>Add a card</span>
        <div style={{ width: 40, flexShrink: 0 }} />
      </div>

      <div className="scroll" style={{ flex: 1, padding: '4px 18px 120px' }}>
        {/* scan CTA */}
        <button style={{ width: '100%', borderRadius: 'var(--r-card)', padding: '16px 18px', display: 'flex', alignItems: 'center', gap: 14, background: 'var(--ink)', boxShadow: 'var(--sh-card)', textAlign: 'left' }}>
          <div style={{ width: 46, height: 46, borderRadius: 14, background: 'var(--accent)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
            <Icon name="scan" size={24} color="#fff" />
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ color: '#fff', fontSize: 15.5, fontWeight: 700 }}>Scan card barcode</div>
            <div style={{ color: 'rgba(255,255,255,.6)', fontSize: 12.5, marginTop: 1 }}>Point at the back of any loyalty card</div>
          </div>
          <Icon name="chevR" size={18} color="rgba(255,255,255,.5)" />
        </button>

        {/* search */}
        <div style={{ marginTop: 14, display: 'flex', alignItems: 'center', gap: 9, background: 'var(--paper)', border: '1px solid var(--line)', borderRadius: 14, padding: '11px 14px', boxShadow: 'var(--sh-card)' }}>
          <Icon name="search" size={19} color="var(--ink-3)" />
          <input placeholder="Search 300+ brands" style={{ border: 'none', outline: 'none', background: 'transparent', flex: 1, fontFamily: 'var(--ui)', fontSize: 15, color: 'var(--ink)' }} />
        </div>

        {/* brand grid */}
        <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, margin: '20px 2px 10px', textTransform: 'uppercase', letterSpacing: 0.3 }}>Popular in Australia</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
          {BRANDS.map(b => {
            const on = sel && sel.name === b.name;
            return (
              <button key={b.name} onClick={() => setSel(b)} style={{ borderRadius: 16, padding: '14px 8px', background: 'var(--paper)', border: '1.5px solid ' + (on ? b.c : 'var(--line)'), boxShadow: on ? '0 8px 18px -10px ' + b.c : 'var(--sh-card)', display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, transition: 'all .18s' }}>
                <div style={{ width: 44, height: 44, borderRadius: 13, background: b.c, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 15 }}>{b.i}</div>
                <span style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--ink-2)', textAlign: 'center', lineHeight: 1.15 }}>{b.name}</span>
              </button>
            );
          })}
        </div>

        {/* number */}
        {sel && (
          <div style={{ animation: 'sc-fade-up .3s both' }}>
            <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, margin: '20px 2px 8px', textTransform: 'uppercase', letterSpacing: 0.3 }}>{sel.name} number</div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, background: 'var(--paper)', border: '1px solid var(--line)', borderRadius: 14, padding: '13px 15px', boxShadow: 'var(--sh-card)' }}>
              <div style={{ width: 30, height: 30, borderRadius: 9, background: sel.c, display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 12, flexShrink: 0 }}>{sel.i}</div>
              <input value={num} onChange={e => setNum(e.target.value)} placeholder="Enter card number" inputMode="numeric" style={{ flex: 1, border: 'none', outline: 'none', background: 'transparent', fontFamily: 'var(--ui)', fontSize: 15, fontWeight: 600, color: 'var(--ink)' }} />
            </div>
          </div>
        )}
      </div>

      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, padding: '14px 18px 34px', background: 'linear-gradient(transparent, var(--cream) 28%)' }}>
        <button disabled={!sel} onClick={() => setDone(true)} style={{ width: '100%', height: 56, borderRadius: 18, fontSize: 17, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, background: sel ? 'var(--accent)' : 'var(--line)', color: sel ? '#fff' : 'var(--ink-3)', boxShadow: sel ? '0 12px 24px -10px var(--accent)' : 'none', transition: 'all .2s', whiteSpace: 'nowrap' }}>
          <Icon name="plus" size={20} color={sel ? '#fff' : 'var(--ink-3)'} sw={2.3} /> Add to wallet
        </button>
      </div>
    </div>
  );
}

function LoyaltyCardDetail({ card, onClose }) {
  if (!card) return null;
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 74, background: 'linear-gradient(165deg, ' + card.c1 + ', ' + card.c2 + ')', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <div style={{ padding: '54px 18px 0', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 999, background: 'rgba(255,255,255,.2)', backdropFilter: 'blur(8px)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="close" size={20} color="#fff" />
        </button>
        <span style={{ fontSize: 11.5, fontWeight: 700, color: '#fff', background: 'rgba(255,255,255,.2)', padding: '6px 12px', borderRadius: 999, whiteSpace: 'nowrap' }}>{card.pts}</span>
      </div>

      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '0 22px', textAlign: 'center' }}>
        <div style={{ color: '#fff', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 30, letterSpacing: -0.5 }}>{card.brand}</div>
        <div style={{ color: 'rgba(255,255,255,.8)', fontSize: 14, marginTop: 3 }}>{card.sub}</div>

        {/* large scannable barcode */}
        <div style={{ background: '#fff', borderRadius: 20, padding: '22px 22px 18px', marginTop: 28, width: '100%', maxWidth: 320, boxShadow: '0 24px 50px -20px rgba(0,0,0,.5)' }}>
          <div style={{ height: 120, backgroundImage: 'repeating-linear-gradient(90deg, #111 0 2px, transparent 2px 4px, #111 4px 7px, transparent 7px 10px, #111 10px 12px, transparent 12px 17px)' }} />
          <div style={{ marginTop: 16, fontSize: 17, fontWeight: 700, color: '#111', fontVariantNumeric: 'tabular-nums', letterSpacing: 2 }}>{card.num}</div>
        </div>

        <div style={{ display: 'flex', alignItems: 'center', gap: 7, marginTop: 24, color: 'rgba(255,255,255,.85)', fontSize: 13.5, fontWeight: 500 }}>
          <Icon name="sparkles" size={16} color="#fff" fill /> Screen brightness boosted for scanning
        </div>
      </div>

      <div style={{ padding: '0 18px 40px', display: 'flex', gap: 10 }}>
        <button style={{ flex: 1, height: 54, borderRadius: 17, background: 'rgba(255,255,255,.95)', color: card.c2, fontSize: 16, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, whiteSpace: 'nowrap' }}>
          <Icon name="share" size={19} color={card.c2} /> Share
        </button>
        <button onClick={onClose} style={{ flex: 1, height: 54, borderRadius: 17, background: 'rgba(255,255,255,.16)', border: '1px solid rgba(255,255,255,.3)', color: '#fff', fontSize: 16, fontWeight: 700, whiteSpace: 'nowrap' }}>Done</button>
      </div>
    </div>
  );
}

Object.assign(window, { LoyaltyScreen, AddLoyaltyScreen, LoyaltyCardDetail });