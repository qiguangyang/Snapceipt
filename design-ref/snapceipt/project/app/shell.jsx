// shell.jsx — app root, navigation, tab bar, theming
const { useState, useEffect } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "personalPalette": ["#E8602C", "#FDEBE0", "#C2461A"],
  "businessPalette": ["#0E7C72", "#DCF0ED", "#0A5950"],
  "toggleStyle": "segmented",
  "snapStyle": "feature",
  "iconStyle": "regular",
  "profileCount": 3,
  "multiStyle": "scroll"
}/*EDITMODE-END*/;

const PROFILES = {
  personal: { name: 'Maya Reyes', initials: 'MR' },
  business: { name: 'Studio North', initials: 'SN' },
};

function TabBar({ tab, go, onSnap }) {
  const items = [
    { id: 'home', icon: 'home', label: 'Home' },
    { id: 'txns', icon: 'receipt', label: 'Activity' },
    { id: 'snap', icon: 'camera', label: 'Snap' },
    { id: 'reports', icon: 'chart', label: 'Reports' },
    { id: 'profile', icon: 'user', label: 'Profile' },
  ];
  return (
    <div style={{ position: 'absolute', left: 0, right: 0, bottom: 0, zIndex: 40, paddingBottom: 22, pointerEvents: 'none' }}>
      <div style={{ position: 'absolute', inset: 0, background: 'linear-gradient(transparent, var(--cream) 55%)' }} />
      <div style={{
        position: 'relative', margin: '0 16px', height: 64, borderRadius: 26,
        background: 'rgba(255,255,255,.82)', backdropFilter: 'blur(18px) saturate(180%)',
        WebkitBackdropFilter: 'blur(18px) saturate(180%)',
        border: '1px solid var(--line)', boxShadow: '0 12px 30px -12px rgba(33,28,24,.28)',
        display: 'flex', alignItems: 'center', justifyContent: 'space-around', pointerEvents: 'auto',
      }}>
        {items.map(it => {
          if (it.id === 'snap') {
            return (
              <button key="snap" onClick={onSnap} style={{ width: 58, height: 58, borderRadius: 20, marginTop: -26, background: 'linear-gradient(150deg, var(--accent), var(--accent-deep))', display: 'flex', alignItems: 'center', justifyContent: 'center', boxShadow: 'var(--sh-fab)', border: '3px solid var(--cream)' }}>
                <Icon name="camera" size={26} color="#fff" />
              </button>
            );
          }
          const active = tab === it.id;
          return (
            <button key={it.id} onClick={() => go(it.id)} style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, padding: '4px 0' }}>
              <Icon name={it.icon} size={23} color={active ? 'var(--accent)' : 'var(--ink-3)'} fill={false} sw={active ? 2.1 : 1.8} />
              <span style={{ fontSize: 10.5, fontWeight: 700, color: active ? 'var(--accent)' : 'var(--ink-3)' }}>{it.label}</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}

function AlertsSheet({ onClose }) {
  const items = [
    { icon: 'shield', tint: 'var(--income)', soft: 'var(--income-soft)', title: 'GST quarter due soon', sub: 'BAS for Q4 is due 28 Jul. You\'re tracking $1,287 deductible.', t: '2h' },
    { icon: 'sparkles', tint: 'var(--accent)', soft: 'var(--accent-soft)', title: '3 receipts auto-sorted', sub: 'We categorised your latest receipts. Tap to review.', t: '5h' },
    { icon: 'film', tint: '#7B5BD6', soft: '#EBE5F8', title: 'Subscription renewing', sub: 'Adobe Creative Cloud ($76.99) renews tomorrow.', t: '1d' },
    { icon: 'wallet', tint: 'var(--p)', soft: 'var(--p-soft)', title: 'Budget check-in', sub: 'You\'ve used 11% of your groceries budget this month.', t: '2d' },
  ];
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 75, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      <div style={{ padding: '54px 18px 12px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="arrowLeft" size={20} color="var(--ink-2)" />
        </button>
        <span style={{ fontSize: 16, fontWeight: 700 }}>Alerts</span>
        <div style={{ width: 40 }} />
      </div>
      <div className="scroll" style={{ flex: 1, padding: '4px 18px 30px' }}>
        {items.map((a, i) => (
          <Card key={i} pad={14} style={{ marginBottom: 10, display: 'flex', gap: 12, alignItems: 'flex-start' }}>
            <IconCircle name={a.icon} tint={a.tint} soft={a.soft} fill={a.icon === 'sparkles'} />
            <div style={{ flex: 1 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                <span style={{ fontSize: 14.5, fontWeight: 700 }}>{a.title}</span>
                <span style={{ fontSize: 11.5, color: 'var(--ink-3)' }}>{a.t}</span>
              </div>
              <p style={{ margin: '3px 0 0', fontSize: 13, color: 'var(--ink-2)', lineHeight: 1.4 }}>{a.sub}</p>
            </div>
          </Card>
        ))}
      </div>
    </div>
  );
}

function ProfilePickerSheet({ profiles, activeId, onSelect, onAdd, onClose }) {
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 76, display: 'flex', flexDirection: 'column', justifyContent: 'flex-end' }}>
      <div onClick={onClose} style={{ position: 'absolute', inset: 0, background: 'rgba(20,16,12,.4)', animation: 'sc-fade .25s both' }} />
      <div style={{ position: 'relative', background: 'var(--cream)', borderRadius: '28px 28px 0 0', padding: '12px 18px 38px', animation: 'sc-rise .32s cubic-bezier(.22,.61,.36,1) both' }}>
        <div style={{ width: 40, height: 5, borderRadius: 999, background: 'var(--line)', margin: '0 auto 16px' }} />
        <div style={{ fontSize: 20, fontWeight: 700, fontFamily: 'var(--display)' }}>Switch profile</div>
        <p style={{ fontSize: 13.5, color: 'var(--ink-2)', margin: '4px 0 16px' }}>Each profile keeps its own receipts, budgets &amp; tax.</p>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {profiles.map(p => {
            const on = p.id === activeId;
            return (
              <button key={p.id} onClick={() => onSelect(p.id)} style={{
                display: 'flex', alignItems: 'center', gap: 13, padding: '12px 14px', borderRadius: 16, textAlign: 'left',
                background: 'var(--paper)', border: '1.5px solid ' + (on ? p.palette[0] : 'var(--line)'), boxShadow: on ? 'none' : 'var(--sh-card)',
              }}>
                <div style={{ width: 42, height: 42, borderRadius: 13, background: 'linear-gradient(135deg,' + p.palette[0] + ',' + p.palette[2] + ')', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 16 }}>{p.initials}</div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 15.5, fontWeight: 700 }}>{p.name}</div>
                  <div style={{ fontSize: 12.5, color: 'var(--ink-3)', textTransform: 'capitalize' }}>{p.type}</div>
                </div>
                {on
                  ? <div style={{ width: 24, height: 24, borderRadius: 999, background: p.palette[0], display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon name="check" size={15} color="#fff" sw={2.8} /></div>
                  : <div style={{ width: 24, height: 24, borderRadius: 999, border: '2px solid var(--line)' }} />}
              </button>
            );
          })}
          <button onClick={onAdd} style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8, padding: '14px', borderRadius: 16, background: 'transparent', border: '1px dashed var(--line)', color: 'var(--ink-2)', fontWeight: 700, fontSize: 14.5, whiteSpace: 'nowrap' }}>
            <Icon name="plus" size={19} color="var(--ink-2)" /> Add a profile
          </button>
        </div>
      </div>
    </div>
  );
}

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const [tab, setTab] = useState(() => localStorage.getItem('sc-tab') || 'home');
  const [txns, setTxns] = useState(SEED);
  const [overlay, setOverlay] = useState(null);   // 'capture' | 'alerts' | 'export' | 'addProfile' | 'profilePicker'
  const [detail, setDetail] = useState(null);
  const [activeId, setActiveId] = useState(() => localStorage.getItem('sc-active') || 'personal');
  const [pageProfile, setPageProfile] = useState(null);
  const [loyaltyCard, setLoyaltyCard] = useState(null);

  useEffect(() => { localStorage.setItem('sc-tab', tab); }, [tab]);

  // expose tweak-driven component variants
  window.__sc = { toggle: t.toggleStyle, snap: t.snapStyle, multi: t.multiStyle };

  const pp = t.personalPalette, bp = t.businessPalette;
  const palVars = {
    '--p': pp[0], '--p-soft': pp[1], '--p-deep': pp[2],
    '--b': bp[0], '--b-soft': bp[1], '--b-deep': bp[2],
  };

  // multi-profile model — first two reuse the tweakable accents
  const ALL_PROFILES = [
    { id: 'personal', name: 'Personal',     type: 'personal', initials: 'P',  palette: pp },
    { id: 'studio',   name: 'Studio North', type: 'business', initials: 'SN', palette: bp },
    { id: 'lumen',    name: 'Lumen Studio', type: 'business', initials: 'LS', palette: ['#3F5BB0', '#E7EAF8', '#2C4290'] },
    { id: 'rentals',  name: 'Rentals',      type: 'business', initials: 'RP', palette: ['#2F7A55', '#DFF0E6', '#205B3D'] },
  ];
  const profiles = ALL_PROFILES.slice(0, t.profileCount);
  const active = profiles.find(p => p.id === activeId) || profiles[0];
  const mode = active.type;
  const profile = { name: active.name, initials: active.initials, palette: active.palette, type: active.type };

  const setActive = (id) => { setActiveId(id); localStorage.setItem('sc-active', id); };
  const setMode = (m) => { const p = profiles.find(x => x.type === m); if (p) setActive(p.id); };

  const go = (route, payload) => {
    if (route === 'capture') return setOverlay('capture');
    if (route === 'alerts') return setOverlay('alerts');
    if (route === 'export') return setOverlay('export');
    if (route === 'addProfile') return setOverlay('addProfile');
    if (route === 'profilePicker') return setOverlay('profilePicker');
    if (route === 'categories') return setOverlay('categories');
    if (route === 'tax') return setOverlay('tax');
    if (route === 'banks') return setOverlay('banks');
    if (route === 'mileage') return setOverlay('mileage');
    if (route === 'wfh') return setOverlay('wfh');
    if (route === 'quote') return setOverlay('quote');
    if (route === 'manual') return setOverlay('manual');
    if (route === 'loyalty') return setOverlay('loyalty');
    if (route === 'loyaltyAdd') return setOverlay('loyaltyAdd');
    if (route === 'loyaltyCard') { setLoyaltyCard(payload); return setOverlay('loyaltyCard'); }
    if (route === 'profileDetail') { setPageProfile(payload); return setOverlay('profileDetail'); }
    if (route === 'txn') return setDetail(payload);
    setTab(route);
  };

  const onSave = (tx) => { setTxns(prev => [{ ...tx, id: 'n' + Date.now() }, ...prev]); };

  const accentVars = { '--accent': active.palette[0], '--accent-soft': active.palette[1], '--accent-deep': active.palette[2] };
  const iconClass = t.iconStyle === 'regular' ? '' : ' icons-' + t.iconStyle;

  return (
    <IOSDevice>
      <div className={'app-root' + iconClass} style={{ height: '100%', position: 'relative', overflow: 'hidden', background: 'var(--cream)', ...palVars, ...accentVars }}>
        <div key={tab + activeId} className="screen-enter" style={{ height: '100%' }}>
          {tab === 'home' && <HomeScreen mode={mode} setMode={setMode} txns={txns} profile={profile} go={go} profiles={profiles} activeId={activeId} setActive={setActive} />}
          {tab === 'txns' && <TransactionsScreen txns={txns} mode={mode} go={go} />}
          {tab === 'reports' && <ReportsScreen txns={txns} mode={mode} go={go} />}
          {tab === 'profile' && <ProfileScreen mode={mode} setMode={setMode} profile={profile} go={go} profiles={profiles} activeId={activeId} setActive={setActive} />}
        </div>

        <TabBar tab={tab} go={go} onSnap={() => setOverlay('capture')} />

        {detail && <TxnDetail t={detail} onClose={() => setDetail(null)} />}
        {overlay === 'alerts' && <AlertsSheet onClose={() => setOverlay(null)} />}
        {overlay === 'export' && <ExportSheet onClose={() => setOverlay(null)} />}
        {overlay === 'addProfile' && <AddProfileScreen onClose={() => setOverlay(null)} onCreate={(p) => { setMode(p.type); setOverlay(null); }} />}
        {overlay === 'profilePicker' && <ProfilePickerSheet profiles={profiles} activeId={activeId} onSelect={(id) => { setActive(id); setOverlay(null); }} onAdd={() => setOverlay('addProfile')} onClose={() => setOverlay(null)} />}
        {overlay === 'categories' && <CategoriesScreen onClose={() => setOverlay(null)} />}
        {overlay === 'tax' && <TaxScreen onClose={() => setOverlay(null)} />}
        {overlay === 'banks' && <ConnectedBanksScreen onClose={() => setOverlay(null)} />}
        {overlay === 'mileage' && <MileageScreen onClose={() => setOverlay(null)} />}
        {overlay === 'wfh' && <WFHScreen onClose={() => setOverlay(null)} />}
        {overlay === 'quote' && <CreateQuoteScreen onClose={() => setOverlay(null)} />}
        {overlay === 'manual' && <AddManualScreen mode={mode} onClose={() => setOverlay(null)} onSave={onSave} />}
        {overlay === 'loyalty' && <LoyaltyScreen onClose={() => setOverlay(null)} onAdd={() => setOverlay('loyaltyAdd')} onOpen={(c) => go('loyaltyCard', c)} />}
        {overlay === 'loyaltyAdd' && <AddLoyaltyScreen onClose={() => setOverlay('loyalty')} />}
        {overlay === 'loyaltyCard' && <LoyaltyCardDetail card={loyaltyCard} onClose={() => setOverlay('loyalty')} />}
        {overlay === 'profileDetail' && <ProfileDetailScreen profile={pageProfile} isActive={pageProfile && pageProfile.id === activeId} onMakeActive={() => { setActive(pageProfile.id); setOverlay(null); }} onClose={() => setOverlay(null)} />}
        {overlay === 'capture' && (
          <CaptureFlow mode={mode} setMode={setMode} onClose={() => setOverlay(null)} onSave={onSave} />
        )}

        <TweaksPanel>
          <TweakSection label="Profile toggle" />
          <TweakRadio label="2-profile bar" value={t.toggleStyle} options={['segmented', 'pills', 'underline']} onChange={(v) => setTweak('toggleStyle', v)} />
          <TweakSection label="Profiles" />
          <TweakRadio label="Profile count" value={t.profileCount} options={[2, 3, 4]} onChange={(v) => setTweak('profileCount', v)} />
          <TweakSection label="Snap action" />
          <TweakRadio label="Presentation" value={t.snapStyle} options={['feature', 'gradient', 'tile']} onChange={(v) => setTweak('snapStyle', v)} />
          <TweakSection label="Iconography" />
          <TweakRadio label="Weight" value={t.iconStyle} options={['thin', 'regular', 'bold']} onChange={(v) => setTweak('iconStyle', v)} />
          <TweakSection label="Personal accent" />
          <TweakColor label="Palette" value={t.personalPalette} options={[
            ['#E8602C', '#FDEBE0', '#C2461A'],
            ['#DD4B39', '#FBE5E1', '#B5341F'],
            ['#D98A1F', '#FAEEDC', '#AE6A12'],
            ['#C2557A', '#F7E6EE', '#9C3E60'],
          ]} onChange={(v) => setTweak('personalPalette', v)} />
          <TweakSection label="Business accent" />
          <TweakColor label="Palette" value={t.businessPalette} options={[
            ['#0E7C72', '#DCF0ED', '#0A5950'],
            ['#1E5E8C', '#E1ECF5', '#134763'],
            ['#3F5BB0', '#E7EAF8', '#2C4290'],
            ['#2F7A55', '#DFF0E6', '#205B3D'],
          ]} onChange={(v) => setTweak('businessPalette', v)} />
        </TweaksPanel>
      </div>
    </IOSDevice>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
