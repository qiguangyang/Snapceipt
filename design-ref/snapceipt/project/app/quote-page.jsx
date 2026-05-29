// quote-page.jsx — Create Quote (business)
const { useState: useStateQ } = React;

const QUOTE_ITEMS = [
  { desc: 'Brand identity — discovery', qty: 1, price: 1200 },
  { desc: 'Logo & visual system', qty: 1, price: 3400 },
  { desc: 'Brand guidelines document', qty: 1, price: 900 },
];

function CreateQuoteScreen({ onClose }) {
  const [items, setItems] = useStateQ(QUOTE_ITEMS);
  const [gstOn, setGstOn] = useStateQ(true);
  const [done, setDone] = useStateQ(false);

  const subtotal = items.reduce((s, it) => s + it.qty * it.price, 0);
  const gst = gstOn ? subtotal * 0.1 : 0;
  const total = subtotal + gst;

  const removeItem = (i) => setItems(items.filter((_, j) => j !== i));
  const addItem = () => setItems([...items, { desc: 'New line item', qty: 1, price: 0 }]);

  if (done) {
    return (
      <div style={{ position: 'absolute', inset: 0, zIndex: 78, background: 'var(--cream)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 30 }}>
        <div style={{ position: 'relative', width: 104, height: 104, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ position: 'absolute', inset: 0, borderRadius: 999, background: 'var(--income)', animation: 'sc-ring 1.1s ease-out .1s' }} />
          <div style={{ width: 92, height: 92, borderRadius: 28, background: 'var(--income)', display: 'flex', alignItems: 'center', justifyContent: 'center', animation: 'sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both', boxShadow: '0 14px 30px -10px var(--income)' }}>
            <svg width="50" height="50" viewBox="0 0 24 24" fill="none"><path d="M5 12.5 10 17.5 19.5 7" stroke="#fff" strokeWidth="2.8" strokeLinecap="round" strokeLinejoin="round" strokeDasharray="48" style={{ animation: 'sc-check .5s .35s ease-out both' }} /></svg>
          </div>
        </div>
        <div style={{ fontSize: 23, fontWeight: 700, fontFamily: 'var(--display)', marginTop: 24, animation: 'sc-fade-up .4s .35s both' }}>Quote sent!</div>
        <p style={{ fontSize: 14.5, color: 'var(--ink-2)', textAlign: 'center', marginTop: 6, lineHeight: 1.45, animation: 'sc-fade-up .4s .45s both' }}>
          Quote <strong style={{ color: 'var(--ink)' }}>SN-0042</strong> for <strong style={{ color: 'var(--ink)' }}>{fmt(total, { cents: false })}</strong> was emailed to Northwind Studio.
        </p>
        <button onClick={onClose} style={{ marginTop: 28, width: '100%', height: 54, borderRadius: 17, background: 'var(--accent)', color: '#fff', fontSize: 16, fontWeight: 700, animation: 'sc-fade-up .4s .55s both' }}>Done</button>
      </div>
    );
  }

  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 72, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <div style={{ padding: '54px 18px 12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <Icon name="close" size={20} color="var(--ink-2)" />
        </button>
        <span style={{ fontSize: 16, fontWeight: 700, flex: 1, textAlign: 'center', whiteSpace: 'nowrap' }}>New quote</span>
        <div style={{ width: 40, flexShrink: 0, display: 'flex', justifyContent: 'flex-end' }}>
          <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--ink-3)', whiteSpace: 'nowrap' }}>SN-0042</span>
        </div>
      </div>

      <div className="scroll" style={{ flex: 1, padding: '4px 18px 120px' }}>
        {/* client */}
        <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, margin: '4px 2px 8px', textTransform: 'uppercase', letterSpacing: 0.3 }}>Bill to</div>
        <Card pad={14}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={{ width: 42, height: 42, borderRadius: 13, background: 'var(--accent-soft)', display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--accent)', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 15 }}>NW</div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 15, fontWeight: 700 }}>Northwind Studio</div>
              <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1 }}>accounts@northwind.co</div>
            </div>
            <Icon name="chevR" size={17} color="var(--ink-3)" />
          </div>
        </Card>

        {/* line items */}
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', margin: '20px 2px 8px' }}>
          <span style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: 0.3, whiteSpace: 'nowrap' }}>Line items</span>
          <button onClick={addItem} style={{ fontSize: 13, color: 'var(--accent)', fontWeight: 700, display: 'flex', alignItems: 'center', gap: 3 }}><Icon name="plus" size={15} color="var(--accent)" sw={2.3} /> Add</button>
        </div>
        <Card pad="2px 14px">
          {items.map((it, i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '13px 0', borderBottom: i === items.length - 1 ? 'none' : '1px solid var(--line-2)' }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14.5, fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{it.desc}</div>
                <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1 }}>{it.qty} × {fmt(it.price, { cents: false })}</div>
              </div>
              <span className="num" style={{ fontSize: 14.5, fontWeight: 700, whiteSpace: 'nowrap' }}>{fmt(it.qty * it.price, { cents: false })}</span>
              <button onClick={() => removeItem(i)} style={{ padding: 4, flexShrink: 0 }}><Icon name="close" size={16} color="var(--ink-3)" /></button>
            </div>
          ))}
        </Card>

        {/* totals */}
        <Card style={{ marginTop: 14 }} pad="2px 16px">
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '13px 0', borderBottom: '1px solid var(--line-2)' }}>
            <span style={{ fontSize: 14, color: 'var(--ink-2)' }}>Subtotal</span>
            <span className="num" style={{ fontSize: 14, fontWeight: 700 }}>{fmt(subtotal)}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '11px 0', borderBottom: '1px solid var(--line-2)' }}>
            <span style={{ fontSize: 14, color: 'var(--ink-2)', whiteSpace: 'nowrap' }}>GST (10%)</span>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <span className="num" style={{ fontSize: 14, fontWeight: 700, color: gstOn ? 'var(--ink)' : 'var(--ink-3)' }}>{fmt(gst)}</span>
              <button onClick={() => setGstOn(!gstOn)} style={{ width: 42, height: 26, borderRadius: 999, background: gstOn ? 'var(--income)' : 'var(--line)', position: 'relative', transition: 'background .2s' }}>
                <div style={{ position: 'absolute', top: 3, left: gstOn ? 19 : 3, width: 20, height: 20, borderRadius: 999, background: '#fff', transition: 'left .2s', boxShadow: '0 1px 3px rgba(0,0,0,.2)' }} />
              </button>
            </div>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '14px 0' }}>
            <span style={{ fontSize: 15.5, fontWeight: 700 }}>Total</span>
            <span className="num" style={{ fontSize: 22, fontWeight: 700, color: 'var(--accent)' }}>{fmt(total)}</span>
          </div>
        </Card>

        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', marginTop: 16, padding: 14, borderRadius: 'var(--r-inner)', background: 'var(--paper-2)' }}>
          <Icon name="info" size={18} color="var(--ink-3)" style={{ marginTop: 1 }} />
          <p style={{ margin: 0, fontSize: 12.5, color: 'var(--ink-2)', lineHeight: 1.45 }}>Valid for 14 days. Accepted quotes convert straight into an invoice.</p>
        </div>
      </div>

      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, padding: '14px 18px 34px', background: 'linear-gradient(transparent, var(--cream) 28%)', display: 'flex', gap: 10 }}>
        <button style={{ width: 56, height: 56, borderRadius: 18, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
          <Icon name="doc" size={22} color="var(--ink-2)" />
        </button>
        <button onClick={() => setDone(true)} style={{ flex: 1, height: 56, borderRadius: 18, background: 'var(--accent)', color: '#fff', fontSize: 17, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, boxShadow: '0 12px 24px -10px var(--accent)', whiteSpace: 'nowrap' }}>
          <Icon name="share" size={20} color="#fff" /> Send quote
        </button>
      </div>
    </div>
  );
}

Object.assign(window, { CreateQuoteScreen });
