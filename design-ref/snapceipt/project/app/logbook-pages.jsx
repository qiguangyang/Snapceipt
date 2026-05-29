// logbook-pages.jsx — Vehicle logbook (Mileage) & Work-from-home log
const { useState: useStateL } = React;

function LbHeader({ title, onClose, accent }) {
  return (
    <div style={{ padding: '54px 18px 12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8 }}>
      <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
        <Icon name="arrowLeft" size={20} color="var(--ink-2)" />
      </button>
      <span style={{ fontSize: 16, fontWeight: 700, flex: 1, textAlign: 'center', minWidth: 0, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</span>
      <button style={{ width: 40, height: 40, borderRadius: 12, background: accent || 'var(--accent)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, boxShadow: '0 6px 14px -6px ' + (accent || 'var(--accent)') }}>
        <Icon name="plus" size={20} color="#fff" sw={2.3} />
      </button>
    </div>
  );
}

function LbLabel({ children }) {
  return <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, margin: '20px 2px 10px', textTransform: 'uppercase', letterSpacing: 0.3 }}>{children}</div>;
}

function MiniStat({ value, label, tint }) {
  return (
    <Card pad={14} style={{ flex: 1 }}>
      <div className="num" style={{ fontSize: 21, fontWeight: 700, letterSpacing: -0.5, color: tint || 'var(--ink)' }}>{value}</div>
      <div style={{ fontSize: 11.5, color: 'var(--ink-3)', fontWeight: 600, marginTop: 2, whiteSpace: 'nowrap' }}>{label}</div>
    </Card>
  );
}

// ── Vehicle logbook (Mileage) ─────────────────────────────────
const TRIPS = [
  { from: 'Studio', to: 'The Grounds (client)', purpose: 'Client meeting', km: 12.4, date: '2026-05-28', biz: true },
  { from: 'Home', to: 'Northwind HQ', purpose: 'Site visit', km: 28.0, date: '2026-05-26', biz: true },
  { from: 'Studio', to: 'Officeworks', purpose: 'Supplies run', km: 6.2, date: '2026-05-24', biz: true },
  { from: 'Airport', to: 'CBD office', purpose: 'Travel', km: 18.5, date: '2026-05-21', biz: true },
  { from: 'Home', to: 'Beach', purpose: 'Weekend', km: 31.0, date: '2026-05-18', biz: false },
];

function MileageScreen({ onClose }) {
  const [auto, setAuto] = useStateL(true);
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 72, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <LbHeader title="Vehicle logbook" onClose={onClose} />
      <div className="scroll" style={{ flex: 1, padding: '4px 18px 110px' }}>
        {/* hero */}
        <div style={{ borderRadius: 'var(--r-card)', padding: 18, color: '#fff', position: 'relative', overflow: 'hidden', background: 'linear-gradient(150deg, var(--accent), var(--accent-deep))', boxShadow: '0 14px 30px -16px var(--accent)' }}>
          <div style={{ position: 'absolute', right: -24, top: -24, width: 120, height: 120, borderRadius: 999, background: 'rgba(255,255,255,.1)' }} />
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, position: 'relative' }}>
            <Icon name="car" size={20} color="#fff" />
            <span style={{ fontSize: 13, fontWeight: 600, opacity: .9, whiteSpace: 'nowrap' }}>This month · May</span>
            <span style={{ marginLeft: 'auto', fontSize: 11.5, fontWeight: 700, background: 'rgba(255,255,255,.2)', padding: '4px 10px', borderRadius: 999, whiteSpace: 'nowrap' }}>Logbook method</span>
          </div>
          <div className="num" style={{ fontSize: 38, fontWeight: 700, marginTop: 6, lineHeight: 1, position: 'relative' }}>342 <span style={{ fontSize: 20, fontWeight: 600, opacity: .85 }}>km</span></div>
          <div style={{ display: 'flex', gap: 18, marginTop: 14, position: 'relative' }}>
            <div>
              <div style={{ fontSize: 12, opacity: .85, fontWeight: 600, whiteSpace: 'nowrap' }}>Claimable</div>
              <div className="num" style={{ fontSize: 18, fontWeight: 700, marginTop: 1 }}>$215.00</div>
            </div>
            <div style={{ width: 1, background: 'rgba(255,255,255,.25)' }} />
            <div>
              <div style={{ fontSize: 12, opacity: .85, fontWeight: 600, whiteSpace: 'nowrap' }}>Business use</div>
              <div className="num" style={{ fontSize: 18, fontWeight: 700, marginTop: 1 }}>78%</div>
            </div>
            <div style={{ width: 1, background: 'rgba(255,255,255,.25)' }} />
            <div>
              <div style={{ fontSize: 12, opacity: .85, fontWeight: 600, whiteSpace: 'nowrap' }}>Trips</div>
              <div className="num" style={{ fontSize: 18, fontWeight: 700, marginTop: 1 }}>12</div>
            </div>
          </div>
        </div>

        {/* GPS auto-track */}
        <Card style={{ marginTop: 14 }} pad={14}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <IconCircle name="pin" tint="var(--accent)" size={38} isize={19} />
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 14.5, fontWeight: 700 }}>Auto-track with GPS</div>
              <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1 }}>Detects drives &amp; logs them for you</div>
            </div>
            <button onClick={() => setAuto(!auto)} style={{ width: 46, height: 28, borderRadius: 999, background: auto ? 'var(--income)' : 'var(--line)', position: 'relative', flexShrink: 0, transition: 'background .2s' }}>
              <div style={{ position: 'absolute', top: 3, left: auto ? 21 : 3, width: 22, height: 22, borderRadius: 999, background: '#fff', transition: 'left .2s', boxShadow: '0 1px 3px rgba(0,0,0,.2)' }} />
            </button>
          </div>
        </Card>

        <LbLabel>Recent trips</LbLabel>
        <Card pad="2px 14px">
          {TRIPS.map((t, i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 2px', borderBottom: i === TRIPS.length - 1 ? 'none' : '1px solid var(--line-2)' }}>
              <IconCircle name="car" tint={t.biz ? 'var(--accent)' : 'var(--ink-3)'} soft={t.biz ? 'var(--accent-soft)' : 'var(--paper-2)'} size={40} isize={20} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 5, whiteSpace: 'nowrap', overflow: 'hidden' }}>
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{t.from}</span>
                  <Icon name="arrowRight" size={13} color="var(--ink-3)" />
                  <span style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>{t.to}</span>
                </div>
                <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1, whiteSpace: 'nowrap' }}>{fmtDate(t.date)} · {t.purpose}</div>
              </div>
              <div style={{ textAlign: 'right', flexShrink: 0 }}>
                <div className="num" style={{ fontSize: 14.5, fontWeight: 700, whiteSpace: 'nowrap' }}>{t.km} km</div>
                <div style={{ fontSize: 11, fontWeight: 700, whiteSpace: 'nowrap', color: t.biz ? 'var(--accent)' : 'var(--ink-3)' }}>{t.biz ? 'Business' : 'Personal'}</div>
              </div>
            </div>
          ))}
        </Card>
      </div>

      {/* add trip */}
      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, padding: '14px 18px 34px', background: 'linear-gradient(transparent, var(--cream) 28%)' }}>
        <button style={{ width: '100%', height: 54, borderRadius: 17, background: 'var(--accent)', color: '#fff', fontSize: 16, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, boxShadow: '0 12px 24px -10px var(--accent)', whiteSpace: 'nowrap' }}>
          <Icon name="plus" size={20} color="#fff" sw={2.3} /> Add a trip
        </button>
      </div>
    </div>
  );
}

// ── Work-from-home log ────────────────────────────────────────
const WFH = [
  { date: '2026-05-29', hrs: 7.5, note: 'Design + admin' },
  { date: '2026-05-26', hrs: 8.0, note: 'Client work' },
  { date: '2026-05-23', hrs: 6.5, note: 'Proposals' },
  { date: '2026-05-21', hrs: 7.0, note: 'Deep work' },
  { date: '2026-05-19', hrs: 8.0, note: 'Client work' },
];
const WEEK = [6, 7.5, 8, 6.5, 7, 0, 0];
const DOW = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

function WFHScreen({ onClose }) {
  const maxH = 8;
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 72, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <LbHeader title="Work from home" onClose={onClose} />
      <div className="scroll" style={{ flex: 1, padding: '4px 18px 110px' }}>
        {/* hero */}
        <div style={{ borderRadius: 'var(--r-card)', padding: 18, color: '#fff', position: 'relative', overflow: 'hidden', background: 'linear-gradient(150deg, var(--accent), var(--accent-deep))', boxShadow: '0 14px 30px -16px var(--accent)' }}>
          <div style={{ position: 'absolute', right: -24, top: -24, width: 120, height: 120, borderRadius: 999, background: 'rgba(255,255,255,.1)' }} />
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, position: 'relative' }}>
            <Icon name="wfh" size={20} color="#fff" />
            <span style={{ fontSize: 13, fontWeight: 600, opacity: .9, whiteSpace: 'nowrap' }}>This financial year</span>
            <span style={{ marginLeft: 'auto', fontSize: 11.5, fontWeight: 700, background: 'rgba(255,255,255,.2)', padding: '4px 10px', borderRadius: 999, whiteSpace: 'nowrap' }}>67c / hour</span>
          </div>
          <div className="num" style={{ fontSize: 38, fontWeight: 700, marginTop: 6, lineHeight: 1, position: 'relative' }}>68.0 <span style={{ fontSize: 20, fontWeight: 600, opacity: .85 }}>hrs</span></div>
          <div style={{ display: 'flex', gap: 18, marginTop: 14, position: 'relative' }}>
            <div>
              <div style={{ fontSize: 12, opacity: .85, fontWeight: 600, whiteSpace: 'nowrap' }}>Claimable</div>
              <div className="num" style={{ fontSize: 18, fontWeight: 700, marginTop: 1 }}>$45.56</div>
            </div>
            <div style={{ width: 1, background: 'rgba(255,255,255,.25)' }} />
            <div>
              <div style={{ fontSize: 12, opacity: .85, fontWeight: 600, whiteSpace: 'nowrap' }}>Days logged</div>
              <div className="num" style={{ fontSize: 18, fontWeight: 700, marginTop: 1 }}>11</div>
            </div>
            <div style={{ width: 1, background: 'rgba(255,255,255,.25)' }} />
            <div>
              <div style={{ fontSize: 12, opacity: .85, fontWeight: 600, whiteSpace: 'nowrap' }}>Avg / day</div>
              <div className="num" style={{ fontSize: 18, fontWeight: 700, marginTop: 1 }}>6.2h</div>
            </div>
          </div>
        </div>

        {/* this week bars */}
        <Card style={{ marginTop: 14 }} pad={18}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
            <span style={{ fontSize: 14.5, fontWeight: 700, whiteSpace: 'nowrap' }}>This week</span>
            <span className="num" style={{ fontSize: 13, color: 'var(--ink-3)', fontWeight: 600 }}>35.0 hrs</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'flex-end', gap: 8, height: 96, marginTop: 14 }}>
            {WEEK.map((h, i) => (
              <div key={i} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 6 }}>
                <div style={{ width: '100%', maxWidth: 26, height: 70, display: 'flex', alignItems: 'flex-end' }}>
                  <div style={{ width: '100%', height: Math.max((h / maxH) * 70, 3) + 'px', borderRadius: 7, background: h > 0 ? 'var(--accent)' : 'var(--line)', transition: 'height .5s' }} />
                </div>
                <span style={{ fontSize: 11, color: 'var(--ink-3)', fontWeight: 600 }}>{DOW[i]}</span>
              </div>
            ))}
          </div>
        </Card>

        <LbLabel>Logged days</LbLabel>
        <Card pad="2px 14px">
          {WFH.map((w, i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 2px', borderBottom: i === WFH.length - 1 ? 'none' : '1px solid var(--line-2)' }}>
              <IconCircle name="clock" tint="var(--accent)" size={40} isize={20} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 14.5, fontWeight: 700, whiteSpace: 'nowrap' }}>{fmtDate(w.date, { weekday: 'short', day: 'numeric', month: 'short' })}</div>
                <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{w.note}</div>
              </div>
              <div className="num" style={{ fontSize: 15, fontWeight: 700, flexShrink: 0 }}>{w.hrs.toFixed(1)} h</div>
            </div>
          ))}
        </Card>

        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', marginTop: 16, padding: 14, borderRadius: 'var(--r-inner)', background: 'var(--paper-2)' }}>
          <Icon name="info" size={18} color="var(--ink-3)" style={{ marginTop: 1 }} />
          <p style={{ margin: 0, fontSize: 12.5, color: 'var(--ink-2)', lineHeight: 1.45 }}>The 67c fixed rate covers electricity, internet, phone &amp; stationery. No need to keep separate bills.</p>
        </div>
      </div>

      {/* log hours */}
      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, padding: '14px 18px 34px', background: 'linear-gradient(transparent, var(--cream) 28%)' }}>
        <button style={{ width: '100%', height: 54, borderRadius: 17, background: 'var(--accent)', color: '#fff', fontSize: 16, fontWeight: 700, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, boxShadow: '0 12px 24px -10px var(--accent)', whiteSpace: 'nowrap' }}>
          <Icon name="plus" size={20} color="#fff" sw={2.3} /> Log hours
        </button>
      </div>
    </div>
  );
}

Object.assign(window, { MileageScreen, WFHScreen });
