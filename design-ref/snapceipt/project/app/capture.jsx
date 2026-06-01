// capture.jsx — Snap → Scan → AI Review → Saved (full-screen overlay)
const { useState: useStateC, useEffect: useEffectC } = React;

// Faux receipt rendered for the scan/preview
function ReceiptPaper({ style = {} }) {
  return (
    <div style={{
      background: '#fff', borderRadius: 8, padding: '18px 18px 22px',
      fontFamily: 'var(--display)', color: '#2a2a2a', position: 'relative',
      boxShadow: '0 20px 50px -20px rgba(0,0,0,.6)',
      maskImage: 'linear-gradient(#000 92%, transparent), repeating-linear-gradient(90deg,#000 0 8px,transparent 8px 16px)',
      WebkitMaskImage: 'linear-gradient(#000 92%, transparent)',
      ...style,
    }}>
      <div style={{ textAlign: 'center', fontWeight: 700, fontSize: 15, letterSpacing: 1 }}>THE GROUNDS</div>
      <div style={{ textAlign: 'center', fontSize: 9, color: '#888', marginTop: 2 }}>OF ALEXANDRIA · SYDNEY</div>
      <div style={{ borderTop: '1px dashed #ccc', margin: '12px 0' }} />
      {[['Flat White ×2', '9.00'], ['Big Brekkie', '24.00'], ['Sourdough', '9.50']].map((r, i) => (
        <div key={i} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11, margin: '6px 0', fontVariantNumeric: 'tabular-nums', whiteSpace: 'nowrap' }}>
          <span>{r[0]}</span><span>{r[1]}</span>
        </div>
      ))}
      <div style={{ borderTop: '1px dashed #ccc', margin: '12px 0' }} />
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 10, color: '#888', fontVariantNumeric: 'tabular-nums' }}>
        <span>GST incl.</span><span>3.86</span>
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, fontSize: 16, marginTop: 8, fontVariantNumeric: 'tabular-nums' }}>
        <span>TOTAL</span><span>$42.50</span>
      </div>
      <div style={{ textAlign: 'center', fontSize: 8.5, color: '#aaa', marginTop: 14 }}>28 MAY 2026 · 09:41 · CARD •••• 1009</div>
    </div>
  );
}

// STEP 1 — camera viewfinder
function CameraStep({ onShoot, onClose, mode }) {
  return (
    <div style={{ position: 'absolute', inset: 0, background: '#0c0a09', display: 'flex', flexDirection: 'column' }}>
      {/* faux camera feed */}
      <div style={{ position: 'absolute', inset: 0, background: 'radial-gradient(120% 90% at 50% 40%, #2b2722 0%, #14110e 70%, #0a0807 100%)' }} />
      <div style={{ position: 'absolute', inset: 0, opacity: .5, backgroundImage: 'radial-gradient(circle at 30% 30%, rgba(255,255,255,.05) 1px, transparent 2px)', backgroundSize: '22px 22px' }} />

      {/* receipt on the "table" */}
      <div style={{ position: 'absolute', top: '50%', left: '50%', transform: 'translate(-50%,-50%) rotate(-3deg)', width: 168, opacity: .96 }}>
        <ReceiptPaper />
      </div>

      {/* top controls */}
      <div style={{ position: 'relative', zIndex: 2, paddingTop: 56, display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '56px 18px 0' }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 999, background: 'rgba(255,255,255,.14)', backdropFilter: 'blur(8px)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="close" size={20} color="#fff" />
        </button>
        <div style={{ background: 'rgba(255,255,255,.14)', backdropFilter: 'blur(8px)', borderRadius: 999, padding: '7px 14px', color: '#fff', fontSize: 13, fontWeight: 600, display: 'flex', alignItems: 'center', gap: 6, textTransform: 'capitalize' }}>
          <span style={{ width: 7, height: 7, borderRadius: 999, background: 'var(--accent)' }} /> {mode}
        </div>
        <button style={{ width: 40, height: 40, borderRadius: 999, background: 'rgba(255,255,255,.14)', backdropFilter: 'blur(8px)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="flash" size={20} color="#fff" />
        </button>
      </div>

      {/* framing corners */}
      <div style={{ position: 'absolute', top: '50%', left: '50%', transform: 'translate(-50%,-50%)', width: 230, height: 320, pointerEvents: 'none' }}>
        {[[0,0,1,1],[1,0,-1,1],[0,1,1,-1],[1,1,-1,-1]].map((c, i) => (
          <div key={i} style={{
            position: 'absolute', width: 30, height: 30,
            [c[0] ? 'right' : 'left']: 0, [c[1] ? 'bottom' : 'top']: 0,
            borderTop: c[3] > 0 ? '3px solid rgba(255,255,255,.9)' : 'none',
            borderBottom: c[3] < 0 ? '3px solid rgba(255,255,255,.9)' : 'none',
            borderLeft: c[2] > 0 ? '3px solid rgba(255,255,255,.9)' : 'none',
            borderRight: c[2] < 0 ? '3px solid rgba(255,255,255,.9)' : 'none',
            borderRadius: 6,
          }} />
        ))}
      </div>

      {/* hint */}
      <div style={{ position: 'absolute', bottom: 188, left: 0, right: 0, textAlign: 'center', color: 'rgba(255,255,255,.7)', fontSize: 13, fontWeight: 500 }}>
        Line up your receipt — we'll auto-capture
      </div>

      {/* bottom bar */}
      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, padding: '0 0 46px', zIndex: 2 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 46 }}>
          <button style={{ width: 50, height: 50, borderRadius: 14, background: 'rgba(255,255,255,.14)', backdropFilter: 'blur(8px)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <Icon name="image" size={24} color="#fff" />
          </button>
          <button onClick={onShoot} style={{ width: 78, height: 78, borderRadius: 999, background: 'transparent', border: '4px solid rgba(255,255,255,.85)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <div style={{ width: 60, height: 60, borderRadius: 999, background: '#fff', transition: 'transform .1s' }} />
          </button>
          <button style={{ width: 50, height: 50, borderRadius: 14, background: 'rgba(255,255,255,.14)', backdropFilter: 'blur(8px)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <Icon name="doc" size={24} color="#fff" />
          </button>
        </div>
      </div>
    </div>
  );
}

// STEP 2 — scanning with progressive field detection
function ScanStep({ onDone }) {
  const [found, setFound] = useStateC(0);
  const fields = ['Merchant', 'Date', 'GST', 'Total', 'Category'];
  useEffectC(() => {
    const ts = fields.map((_, i) => setTimeout(() => setFound(i + 1), 500 + i * 360));
    const done = setTimeout(onDone, 500 + fields.length * 360 + 500);
    return () => { ts.forEach(clearTimeout); clearTimeout(done); };
  }, []);
  return (
    <div style={{ position: 'absolute', inset: 0, background: '#0c0a09', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 24 }}>
      <div style={{ position: 'relative', width: 196 }}>
        <ReceiptPaper />
        {/* scan line */}
        <div style={{ position: 'absolute', left: -4, right: -4, height: 3, background: 'linear-gradient(90deg, transparent, var(--accent), transparent)', boxShadow: '0 0 16px 4px var(--accent)', animation: 'sc-scan 1.4s ease-in-out infinite alternate', borderRadius: 999 }} />
        {/* corner glow frame */}
        <div style={{ position: 'absolute', inset: -10, border: '2px solid var(--accent)', borderRadius: 12, opacity: .5 }} />
      </div>

      <div style={{ marginTop: 30, display: 'flex', alignItems: 'center', gap: 9, color: '#fff' }}>
        <Icon name="sparkles" size={20} color="var(--accent)" fill />
        <span style={{ fontSize: 17, fontWeight: 700, fontFamily: 'var(--display)' }}>Reading your receipt…</span>
      </div>

      <div style={{ marginTop: 18, display: 'flex', flexWrap: 'wrap', gap: 8, justifyContent: 'center', maxWidth: 280 }}>
        {fields.map((f, i) => (
          <div key={f} style={{
            display: 'flex', alignItems: 'center', gap: 6, padding: '7px 12px', borderRadius: 999,
            fontSize: 12.5, fontWeight: 600, transition: 'all .3s',
            background: i < found ? 'rgba(255,255,255,.12)' : 'rgba(255,255,255,.04)',
            color: i < found ? '#fff' : 'rgba(255,255,255,.35)',
            border: i < found ? '1px solid var(--accent)' : '1px solid transparent',
          }}>
            {i < found
              ? <Icon name="check" size={13} color="var(--accent)" sw={2.6} />
              : <span style={{ width: 11, height: 11, borderRadius: 999, border: '2px solid rgba(255,255,255,.3)', borderTopColor: 'var(--accent)', animation: 'sc-spin .7s linear infinite' }} />}
            {f}
          </div>
        ))}
      </div>
    </div>
  );
}

// STEP 3 — AI review / categorize
function field(label, value, sub) {
  return (
    <div style={{ flex: 1 }}>
      <div style={{ fontSize: 11.5, color: 'var(--ink-3)', fontWeight: 600, marginBottom: 3 }}>{label}</div>
      <div style={{ fontSize: 15.5, fontWeight: 700, letterSpacing: -0.2 }}>{value}</div>
      {sub && <div style={{ fontSize: 11.5, color: 'var(--ink-3)', marginTop: 1 }}>{sub}</div>}
    </div>
  );
}

function ReviewStep({ mode, setMode, onSave, onClose }) {
  const [cat, setCat] = useStateC('meals');
  const c = CATS[cat];
  return (
    <div style={{ position: 'absolute', inset: 0, background: 'var(--cream)', display: 'flex', flexDirection: 'column' }}>
      {/* header */}
      <div style={{ paddingTop: 54, paddingBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '54px 18px 12px' }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="close" size={20} color="var(--ink-2)" />
        </button>
        <span style={{ fontSize: 17, fontWeight: 700, whiteSpace: 'nowrap' }}>Review receipt</span>
        <button style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="edit" size={19} color="var(--ink-2)" />
        </button>
      </div>

      <div className="scroll" style={{ flex: 1, padding: '0 18px 120px' }}>
        {/* receipt thumb + total */}
        <div style={{ display: 'flex', gap: 14, alignItems: 'center', animation: 'sc-fade-up .4s both' }}>
          <div style={{ width: 64, height: 84, borderRadius: 12, overflow: 'hidden', flexShrink: 0, boxShadow: 'var(--sh-card)', background: '#fff' }}>
            <div style={{ transform: 'scale(.34)', transformOrigin: 'top left', width: 188 }}><ReceiptPaper /></div>
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13, color: 'var(--ink-3)', fontWeight: 600 }}>Total detected</div>
            <div className="num" style={{ fontSize: 34, fontWeight: 700, lineHeight: 1, marginTop: 2 }}>$42.50</div>
            <div style={{ display: 'inline-flex', alignItems: 'center', gap: 5, marginTop: 6, background: 'var(--income-soft)', color: 'var(--income)', padding: '3px 9px', borderRadius: 999, fontSize: 11.5, fontWeight: 700 }}>
              <Icon name="check" size={12} color="var(--income)" sw={2.6} /> incl. $3.86 GST
            </div>
          </div>
        </div>

        {/* AI suggestion banner */}
        <div style={{ marginTop: 16, borderRadius: 'var(--r-inner)', padding: 14, background: 'linear-gradient(135deg, var(--accent-soft), #fff)', border: '1px solid var(--accent)', animation: 'sc-fade-up .4s .08s both' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <Icon name="sparkles" size={18} color="var(--accent)" fill />
            <span style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--accent-deep)' }}>AI categorised this for you</span>
            <span style={{ marginLeft: 'auto', fontSize: 11, fontWeight: 700, color: 'var(--accent-deep)', background: '#fff', padding: '3px 8px', borderRadius: 999 }}>98% match</span>
          </div>
          <p style={{ margin: '8px 0 0', fontSize: 13, color: 'var(--ink-2)', lineHeight: 1.45 }}>
            Looks like a <strong style={{ color: 'var(--ink)' }}>client coffee meeting</strong> — filed under <strong style={{ color: 'var(--ink)' }}>Business · Meals</strong>, claimable at <strong style={{ color: 'var(--ink)' }}>50%</strong>.
          </p>
        </div>

        {/* details card */}
        <Card style={{ marginTop: 14, animation: 'sc-fade-up .4s .14s both' }} pad="2px 16px">
          <div style={{ display: 'flex', padding: '14px 0', borderBottom: '1px solid var(--line-2)' }}>
            {field('Merchant', 'The Grounds')}
            {field('Date', '28 May 2026')}
          </div>
          <div style={{ display: 'flex', alignItems: 'center', padding: '14px 0', borderBottom: '1px solid var(--line-2)' }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 11.5, color: 'var(--ink-3)', fontWeight: 600, marginBottom: 5 }}>Category</div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <IconCircle name={c.icon} tint={c.tint} soft={c.soft} size={32} isize={17} />
                <span style={{ fontSize: 15, fontWeight: 700 }}>{c.label}</span>
              </div>
            </div>
            <Icon name="chevR" size={18} color="var(--ink-3)" />
          </div>
          <div style={{ display: 'flex', padding: '14px 0' }}>
            {field('Payment', 'Amex Business')}
            {field('Tax', 'Client meeting', 'Deductible 50%')}
          </div>
        </Card>

        {/* personal/business choice */}
        <div style={{ marginTop: 16, animation: 'sc-fade-up .4s .2s both' }}>
          <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Assign to profile</div>
          <ModeToggle mode={mode} setMode={setMode} />
        </div>

        {/* attach extras */}
        <div style={{ marginTop: 14, display: 'flex', gap: 8, animation: 'sc-fade-up .4s .26s both' }}>
          <Chip><Icon name="car" size={15} color="var(--ink-2)" /> Add to mileage</Chip>
          <Chip><Icon name="link" size={15} color="var(--ink-2)" /> Match to bank</Chip>
        </div>
      </div>

      {/* save bar */}
      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, padding: '14px 18px 34px', background: 'linear-gradient(transparent, var(--cream) 28%)' }}>
        <button onClick={() => onSave({
          merchant: 'The Grounds', cat, amount: -42.50, date: '2026-05-28',
          mode, tax: 'Client meeting', deductible: 50, method: 'Amex Business', ai: true, gst: 3.86,
        })} style={{
          width: '100%', height: 56, borderRadius: 18, background: 'var(--accent)', color: '#fff',
          fontSize: 17, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
          boxShadow: '0 12px 24px -10px var(--accent)', whiteSpace: 'nowrap',
        }}>
          <Icon name="check" size={20} color="#fff" sw={2.6} /> Save receipt
        </button>
      </div>
    </div>
  );
}

// STEP 4 — saved success
function SavedStep({ mode, onAnother, onDone }) {
  return (
    <div style={{ position: 'absolute', inset: 0, background: 'var(--cream)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 30, overflow: 'hidden' }}>
      {/* confetti */}
      {Array.from({ length: 14 }).map((_, i) => (
        <span key={i} style={{
          position: 'absolute', top: '34%', left: (8 + i * 6.4) + '%',
          width: 8, height: 12, borderRadius: 2,
          background: [ 'var(--accent)', 'var(--income)', '#7B5BD6', '#C99A22', '#2F6FB0'][i % 5],
          animation: `sc-confetti ${1 + (i % 5) * 0.18}s ${(i % 4) * 0.06}s ease-in forwards`,
          opacity: 0,
        }} />
      ))}
      <div style={{ position: 'relative', width: 110, height: 110, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <div style={{ position: 'absolute', inset: 0, borderRadius: 999, background: 'var(--income)', animation: 'sc-ring 1.1s ease-out .1s' }} />
        <div style={{ width: 96, height: 96, borderRadius: 999, background: 'var(--income)', display: 'flex', alignItems: 'center', justifyContent: 'center', animation: 'sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both', boxShadow: '0 14px 30px -10px var(--income)' }}>
          <svg width="50" height="50" viewBox="0 0 24 24" fill="none">
            <path d="M5 12.5 10 17.5 19.5 7" stroke="#fff" strokeWidth="2.8" strokeLinecap="round" strokeLinejoin="round" strokeDasharray="48" style={{ animation: 'sc-check .5s .35s ease-out both' }} />
          </svg>
        </div>
      </div>
      <div style={{ fontSize: 24, fontWeight: 700, fontFamily: 'var(--display)', marginTop: 26, animation: 'sc-fade-up .4s .4s both' }}>Receipt saved!</div>
      <p style={{ fontSize: 14.5, color: 'var(--ink-2)', textAlign: 'center', marginTop: 6, lineHeight: 1.45, animation: 'sc-fade-up .4s .48s both' }}>
        $42.50 added to <strong style={{ color: 'var(--ink)', textTransform: 'capitalize' }}>{mode}</strong> expenses,<br />and tagged <strong style={{ color: 'var(--ink)' }}>50% deductible</strong>.
      </p>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, width: '100%', marginTop: 30, animation: 'sc-fade-up .4s .56s both' }}>
        <button onClick={onAnother} style={{ height: 54, borderRadius: 17, background: 'var(--accent)', color: '#fff', fontSize: 16, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, whiteSpace: 'nowrap' }}>
          <Icon name="camera" size={20} color="#fff" /> Snap another
        </button>
        <button onClick={onDone} style={{ height: 54, borderRadius: 17, background: 'var(--paper)', border: '1px solid var(--line)', color: 'var(--ink)', fontSize: 16, fontWeight: 700 }}>
          Done
        </button>
      </div>
    </div>
  );
}

function CaptureFlow({ mode, setMode, onClose, onSave }) {
  const [step, setStep] = useStateC('camera');
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 80, animation: 'sc-fade .25s both' }}>
      {step === 'camera' && <CameraStep mode={mode} onClose={onClose} onShoot={() => setStep('scan')} />}
      {step === 'scan' && <ScanStep onDone={() => setStep('review')} />}
      {step === 'review' && <ReviewStep mode={mode} setMode={setMode} onClose={onClose} onSave={(t) => { onSave(t); setStep('saved'); }} />}
      {step === 'saved' && <SavedStep mode={mode} onAnother={() => setStep('camera')} onDone={onClose} />}
    </div>
  );
}

Object.assign(window, { CaptureFlow });
