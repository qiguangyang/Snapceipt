// addprofile.jsx — "New profile" creation flow (full-screen overlay)
const { useState: useStateAP } = React;

const AP_ACCENTS = [
  ['#E8602C', '#FDEBE0', '#C2461A'],
  ['#DD4B39', '#FBE5E1', '#B5341F'],
  ['#D98A1F', '#FAEEDC', '#AE6A12'],
  ['#C2557A', '#F7E6EE', '#9C3E60'],
  ['#0E7C72', '#DCF0ED', '#0A5950'],
  ['#1E5E8C', '#E1ECF5', '#134763'],
  ['#3F5BB0', '#E7EAF8', '#2C4290'],
  ['#2F7A55', '#DFF0E6', '#205B3D'],
];

function apInitials(name, type) {
  const t = (name || '').trim();
  if (!t) return type === 'business' ? 'BZ' : 'ME';
  const parts = t.split(/\s+/).filter(Boolean);
  return (parts[0][0] + (parts[1] ? parts[1][0] : (parts[0][1] || ''))).toUpperCase();
}

function APField({ label, value, onChange, placeholder, prefix }) {
  return (
    <div>
      <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, marginBottom: 7, textTransform: 'uppercase', letterSpacing: 0.3 }}>{label}</div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'var(--paper)', border: '1px solid var(--line)', borderRadius: 14, padding: '13px 15px', boxShadow: 'var(--sh-card)' }}>
        {prefix && <span style={{ fontSize: 15.5, color: 'var(--ink-3)', fontWeight: 600 }}>{prefix}</span>}
        <input value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder}
          style={{ border: 'none', outline: 'none', background: 'transparent', flex: 1, fontFamily: 'var(--ui)', fontSize: 15.5, fontWeight: 600, color: 'var(--ink)' }} />
      </div>
    </div>
  );
}

function APSwitch({ on, onClick }) {
  return (
    <button onClick={onClick} style={{ width: 46, height: 28, borderRadius: 999, background: on ? 'var(--income)' : 'var(--line)', position: 'relative', transition: 'background .2s', flexShrink: 0 }}>
      <div style={{ position: 'absolute', top: 3, left: on ? 21 : 3, width: 22, height: 22, borderRadius: 999, background: '#fff', transition: 'left .2s', boxShadow: '0 1px 3px rgba(0,0,0,.2)' }} />
    </button>
  );
}

function TypeCard({ active, icon, title, sub, tint, soft, onClick }) {
  return (
    <button onClick={onClick} style={{
      flex: 1, textAlign: 'left', borderRadius: 'var(--r-inner)', padding: 14,
      background: active ? soft : 'var(--paper)',
      border: '1.5px solid ' + (active ? tint : 'var(--line)'),
      boxShadow: active ? 'none' : 'var(--sh-card)', transition: 'all .2s', position: 'relative',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div style={{ width: 40, height: 40, borderRadius: 12, background: active ? tint : 'var(--paper-2)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name={icon} size={21} color={active ? '#fff' : 'var(--ink-2)'} />
        </div>
        <div style={{ width: 22, height: 22, borderRadius: 999, border: '2px solid ' + (active ? tint : 'var(--line)'), background: active ? tint : 'transparent', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          {active && <Icon name="check" size={13} color="#fff" sw={2.8} />}
        </div>
      </div>
      <div style={{ fontSize: 15.5, fontWeight: 700, marginTop: 11 }}>{title}</div>
      <div style={{ fontSize: 12, color: 'var(--ink-3)', marginTop: 2, lineHeight: 1.3 }}>{sub}</div>
    </button>
  );
}

function AddProfileScreen({ onClose, onCreate }) {
  const [step, setStep] = useStateAP('form');
  const [type, setType] = useStateAP('business');
  const [name, setName] = useStateAP('');
  const [abn, setAbn] = useStateAP('');
  const [gst, setGst] = useStateAP(true);
  const [pal, setPal] = useStateAP(AP_ACCENTS[4]);

  const displayName = name.trim() || (type === 'business' ? 'New business' : 'New profile');
  const valid = name.trim().length > 0;

  if (step === 'done') {
    return (
      <div style={{ position: 'absolute', inset: 0, zIndex: 78, background: 'var(--cream)', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: 30 }}>
        <div style={{ position: 'relative', width: 104, height: 104, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ position: 'absolute', inset: 0, borderRadius: 999, background: pal[0], animation: 'sc-ring 1.1s ease-out .1s' }} />
          <div style={{ width: 92, height: 92, borderRadius: 28, background: 'linear-gradient(150deg, ' + pal[0] + ', ' + pal[2] + ')', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 34, animation: 'sc-pop-in .5s cubic-bezier(.34,1.56,.64,1) both', boxShadow: '0 14px 30px -10px ' + pal[0] }}>
            {apInitials(name, type)}
          </div>
        </div>
        <div style={{ fontSize: 23, fontWeight: 700, fontFamily: 'var(--display)', marginTop: 24, animation: 'sc-fade-up .4s .35s both' }}>Profile created!</div>
        <p style={{ fontSize: 14.5, color: 'var(--ink-2)', textAlign: 'center', marginTop: 6, lineHeight: 1.45, animation: 'sc-fade-up .4s .45s both' }}>
          <strong style={{ color: 'var(--ink)' }}>{displayName}</strong> is ready. Switch into it any time from your profile.
        </p>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10, width: '100%', marginTop: 30, animation: 'sc-fade-up .4s .55s both' }}>
          <button onClick={() => onCreate({ type, name: displayName, pal })} style={{ height: 54, borderRadius: 17, background: pal[0], color: '#fff', fontSize: 16, fontWeight: 700, whiteSpace: 'nowrap' }}>
            Switch to {displayName}
          </button>
          <button onClick={onClose} style={{ height: 54, borderRadius: 17, background: 'var(--paper)', border: '1px solid var(--line)', color: 'var(--ink)', fontSize: 16, fontWeight: 700 }}>
            Done
          </button>
        </div>
      </div>
    );
  }

  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 70, background: 'var(--cream)', display: 'flex', flexDirection: 'column', animation: 'sc-rise .3s cubic-bezier(.22,.61,.36,1) both' }}>
      {/* header */}
      <div style={{ padding: '54px 18px 10px', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <button onClick={onClose} style={{ width: 40, height: 40, borderRadius: 12, background: 'var(--paper)', border: '1px solid var(--line)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <Icon name="arrowLeft" size={20} color="var(--ink-2)" />
        </button>
        <span style={{ fontSize: 16, fontWeight: 700, whiteSpace: 'nowrap' }}>New profile</span>
        <div style={{ width: 40 }} />
      </div>

      <div className="scroll" style={{ flex: 1, padding: '4px 18px 120px' }}>
        {/* live preview */}
        <div style={{ borderRadius: 'var(--r-card)', padding: 18, color: '#fff', position: 'relative', overflow: 'hidden', background: 'linear-gradient(150deg, ' + pal[0] + ', ' + pal[2] + ')', boxShadow: '0 14px 30px -16px ' + pal[0], transition: 'background .3s' }}>
          <div style={{ position: 'absolute', right: -24, top: -24, width: 110, height: 110, borderRadius: 999, background: 'rgba(255,255,255,.1)' }} />
          <div style={{ display: 'flex', alignItems: 'center', gap: 13, position: 'relative' }}>
            <div style={{ width: 52, height: 52, borderRadius: 16, background: 'rgba(255,255,255,.22)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 20 }}>{apInitials(name, type)}</div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 18, fontWeight: 700, letterSpacing: -0.3, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{displayName}</div>
              <div style={{ fontSize: 12.5, opacity: .85, marginTop: 1 }}>{type === 'business' ? (abn ? 'ABN ' + abn : 'Business profile') : 'Personal profile'}</div>
            </div>
            <span style={{ fontSize: 11, fontWeight: 700, background: 'rgba(255,255,255,.2)', padding: '4px 10px', borderRadius: 999, textTransform: 'capitalize' }}>{type}</span>
          </div>
        </div>

        {/* type */}
        <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, margin: '22px 2px 10px', textTransform: 'uppercase', letterSpacing: 0.3 }}>Profile type</div>
        <div style={{ display: 'flex', gap: 10 }}>
          <TypeCard active={type === 'personal'} icon="wallet" title="Personal" sub="Everyday spending & budgets" tint="var(--p)" soft="var(--p-soft)" onClick={() => setType('personal')} />
          <TypeCard active={type === 'business'} icon="building" title="Business" sub="ABN, GST & tax deductions" tint="var(--b)" soft="var(--b-soft)" onClick={() => setType('business')} />
        </div>

        {/* details */}
        <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, margin: '22px 2px 12px', textTransform: 'uppercase', letterSpacing: 0.3 }}>Details</div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
          <APField label={type === 'business' ? 'Business name' : 'Profile name'} value={name} onChange={setName} placeholder={type === 'business' ? 'e.g. Studio North' : 'e.g. Personal'} />
          {type === 'business' && (
            <>
              <APField label="ABN" value={abn} onChange={setAbn} placeholder="12 345 678 901" />
              <div style={{ display: 'flex', alignItems: 'center', gap: 12, background: 'var(--paper)', border: '1px solid var(--line)', borderRadius: 14, padding: '13px 15px', boxShadow: 'var(--sh-card)' }}>
                <IconCircle name="shield" tint="var(--income)" soft="var(--income-soft)" size={36} isize={19} />
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 14.5, fontWeight: 700 }}>Registered for GST</div>
                  <div style={{ fontSize: 12, color: 'var(--ink-3)', marginTop: 1 }}>Track GST on every receipt</div>
                </div>
                <APSwitch on={gst} onClick={() => setGst(!gst)} />
              </div>
            </>
          )}
        </div>

        {/* accent */}
        <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, margin: '22px 2px 12px', textTransform: 'uppercase', letterSpacing: 0.3 }}>Accent colour</div>
        <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
          {AP_ACCENTS.map((p, i) => {
            const on = p[0] === pal[0];
            return (
              <button key={i} onClick={() => setPal(p)} style={{ width: 44, height: 44, borderRadius: 14, background: 'linear-gradient(150deg, ' + p[0] + ', ' + p[2] + ')', position: 'relative', boxShadow: on ? '0 0 0 2.5px var(--cream), 0 0 0 5px ' + p[0] : 'var(--sh-card)', transition: 'box-shadow .15s' }}>
                {on && <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}><Icon name="check" size={20} color="#fff" sw={2.8} /></div>}
              </button>
            );
          })}
        </div>

        {/* note */}
        <div style={{ display: 'flex', gap: 10, alignItems: 'flex-start', marginTop: 22, padding: 14, borderRadius: 'var(--r-inner)', background: 'var(--paper-2)' }}>
          <Icon name="info" size={18} color="var(--ink-3)" style={{ marginTop: 1 }} />
          <p style={{ margin: 0, fontSize: 12.5, color: 'var(--ink-2)', lineHeight: 1.45 }}>
            We'll set up {type === 'business' ? 'tax categories, GST tracking and logbooks' : 'everyday categories and budgets'} for this profile. You can change everything later.
          </p>
        </div>
      </div>

      {/* create bar */}
      <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, padding: '14px 18px 34px', background: 'linear-gradient(transparent, var(--cream) 28%)' }}>
        <button disabled={!valid} onClick={() => setStep('done')} style={{
          width: '100%', height: 56, borderRadius: 18, fontSize: 17, fontWeight: 700,
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
          background: valid ? pal[0] : 'var(--line)', color: valid ? '#fff' : 'var(--ink-3)',
          boxShadow: valid ? '0 12px 24px -10px ' + pal[0] : 'none', transition: 'all .2s', cursor: valid ? 'pointer' : 'default', whiteSpace: 'nowrap',
        }}>
          <Icon name="plus" size={20} color={valid ? '#fff' : 'var(--ink-3)'} sw={2.4} /> Create profile
        </button>
      </div>
    </div>
  );
}

Object.assign(window, { AddProfileScreen });
