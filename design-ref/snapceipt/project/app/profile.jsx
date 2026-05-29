// profile.jsx — profiles, settings
function ProfileCard({ active, tint, soft, deep, title, sub, initials, onClick }) {
  return (
    <button onClick={onClick} style={{
      flex: 1, textAlign: 'left', borderRadius: 'var(--r-card)', padding: 16,
      background: active ? 'linear-gradient(150deg, ' + tint + ', ' + deep + ')' : 'var(--paper)',
      border: '1px solid ' + (active ? tint : 'var(--line)'),
      boxShadow: active ? '0 14px 28px -14px ' + tint : 'var(--sh-card)',
      position: 'relative', overflow: 'hidden', transition: 'all .25s',
    }}>
      {active && <div style={{ position: 'absolute', right: -20, top: -20, width: 80, height: 80, borderRadius: 999, background: 'rgba(255,255,255,.1)' }} />}
      <div style={{ width: 40, height: 40, borderRadius: 12, background: active ? 'rgba(255,255,255,.22)' : soft, display: 'flex', alignItems: 'center', justifyContent: 'center', color: active ? '#fff' : tint, fontFamily: 'var(--display)', fontWeight: 700, fontSize: 16 }}>{initials}</div>
      <div style={{ fontSize: 15.5, fontWeight: 700, marginTop: 12, color: active ? '#fff' : 'var(--ink)' }}>{title}</div>
      <div style={{ fontSize: 12, marginTop: 1, color: active ? 'rgba(255,255,255,.8)' : 'var(--ink-3)' }}>{sub}</div>
      {active && <div style={{ marginTop: 10, display: 'inline-flex', alignItems: 'center', gap: 4, fontSize: 11, fontWeight: 700, color: '#fff', background: 'rgba(255,255,255,.2)', padding: '3px 9px', borderRadius: 999 }}><Icon name="check" size={12} color="#fff" sw={2.6} /> Active</div>}
    </button>
  );
}

function SettingRow({ icon, tint, soft, label, detail, last, toggle, on, onClick }) {
  return (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '13px 0', borderBottom: last ? 'none' : '1px solid var(--line-2)', cursor: onClick ? 'pointer' : 'default' }}>
      <IconCircle name={icon} tint={tint || 'var(--ink-2)'} soft={soft || 'var(--paper-2)'} size={36} isize={19} />
      <span style={{ flex: 1, fontSize: 15, fontWeight: 600 }}>{label}</span>
      {detail && <span style={{ fontSize: 13.5, color: 'var(--ink-3)', fontWeight: 500, whiteSpace: 'nowrap' }}>{detail}</span>}
      {toggle ? (
        <div style={{ width: 46, height: 28, borderRadius: 999, background: on ? 'var(--income)' : 'var(--line)', position: 'relative', transition: 'background .2s', flexShrink: 0 }}>
          <div style={{ position: 'absolute', top: 3, left: on ? 21 : 3, width: 22, height: 22, borderRadius: 999, background: '#fff', transition: 'left .2s', boxShadow: '0 1px 3px rgba(0,0,0,.2)' }} />
        </div>
      ) : <Icon name="chevR" size={17} color="var(--ink-3)" />}
    </div>
  );
}

function ProfileScreen({ mode, setMode, profile, go, profiles, activeId, setActive }) {
  const list = profiles || [];
  return (
    <div className="scroll" style={{ height: '100%', padding: '54px 18px 124px' }}>
      <h1 style={{ fontFamily: 'var(--display)', fontSize: 30, fontWeight: 700, letterSpacing: -0.6, margin: 0 }}>Profile</h1>

      {/* identity */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginTop: 16 }}>
        <div style={{ width: 60, height: 60, borderRadius: 20, background: 'linear-gradient(135deg, var(--accent), var(--accent-deep))', display: 'flex', alignItems: 'center', justifyContent: 'center', color: '#fff', fontFamily: 'var(--display)', fontWeight: 700, fontSize: 24, boxShadow: '0 10px 22px -10px var(--accent)' }}>MR</div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 19, fontWeight: 700, letterSpacing: -0.3 }}>Maya Reyes</div>
          <div style={{ fontSize: 13.5, color: 'var(--ink-3)' }}>maya@studionorth.co</div>
        </div>
        <span style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--accent-deep)', background: 'var(--accent-soft)', padding: '5px 11px', borderRadius: 999 }}>Pro</span>
      </div>

      {/* profile switcher */}
      <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink-3)', margin: '22px 2px 10px', textTransform: 'uppercase', letterSpacing: 0.3 }}>Profiles · {list.length}</div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
        {list.map(p => (
          <ProfileCard key={p.id} active={p.id === activeId} tint={p.palette[0]} deep={p.palette[2]} soft={p.palette[1]}
            title={p.name} sub={p.type === 'business' ? 'Business · tap to manage' : 'Everyday spending'} initials={p.initials}
            onClick={() => go('profileDetail', p)} />
        ))}
      </div>
      <button onClick={() => go('addProfile')} style={{ width: '100%', marginTop: 10, padding: '12px', borderRadius: 14, background: 'var(--paper)', border: '1px dashed var(--line)', color: 'var(--ink-2)', fontWeight: 600, fontSize: 14, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7, whiteSpace: 'nowrap' }}>
        <Icon name="plus" size={18} color="var(--ink-2)" /> Add another profile
      </button>

      {/* groups */}
      <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink-3)', margin: '22px 2px 10px', textTransform: 'uppercase', letterSpacing: 0.3 }}>Capture &amp; tax</div>
      <Card pad="2px 16px">
        <SettingRow icon="sparkles" tint="var(--accent)" soft="var(--accent-soft)" label="AI auto-categorise" toggle on />
        <SettingRow icon="tag" tint="#7B5BD6" soft="#EBE5F8" label="Categories &amp; rules" detail="9" onClick={() => go('categories')} />
        <SettingRow icon="shield" tint="var(--income)" soft="var(--income-soft)" label="Tax & GST settings" detail="FY25–26" onClick={() => go('tax')} />
        <SettingRow icon="bank" tint="#2F6FB0" soft="#E2ECF6" label="Connected banks" detail="2 linked" onClick={() => go('banks')} last />
      </Card>

      <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink-3)', margin: '20px 2px 10px', textTransform: 'uppercase', letterSpacing: 0.3 }}>App</div>
      <Card pad="2px 16px">
        <SettingRow icon="bell" label="Notifications &amp; alerts" toggle on />
        <SettingRow icon="download" label="Export &amp; backup" />
        <SettingRow icon="lock" label="Privacy &amp; security" detail="Face ID" />
        <SettingRow icon="info" label="Help &amp; support" last />
      </Card>

      <button style={{ width: '100%', marginTop: 18, padding: '15px', borderRadius: 15, background: 'var(--paper)', border: '1px solid var(--line)', color: 'var(--alert)', fontWeight: 700, fontSize: 15, display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8 }}>
        <Icon name="logout" size={19} color="var(--alert)" /> Sign out
      </button>
      <div style={{ textAlign: 'center', fontSize: 12, color: 'var(--ink-3)', marginTop: 16 }}>Snapceipt · v1.0 · Snap it. Sort it. Sorted.</div>
    </div>
  );
}

Object.assign(window, { ProfileScreen });
