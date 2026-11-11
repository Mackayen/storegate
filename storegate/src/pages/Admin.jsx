import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../supabase.js'
import { ROLES, STEP_ROLES, fmtDate, roleName } from '../fmt.js'

const TABS = ['Users', 'Items', 'Storerooms', 'Sign off steps', 'Audit log']

export default function Admin() {
  const [tab, setTab] = useState('Users')
  return (
    <>
      <h1>Admin</h1>
      <div className="tabs">
        {TABS.map((t) => (
          <button key={t} className={t === tab ? 'on' : ''} onClick={() => setTab(t)}>{t}</button>
        ))}
      </div>
      {tab === 'Users' && <Users />}
      {tab === 'Items' && <Items />}
      {tab === 'Storerooms' && <Storerooms />}
      {tab === 'Sign off steps' && <Steps />}
      {tab === 'Audit log' && <Audit />}
    </>
  )
}

function Users() {
  const [rows, setRows] = useState([])
  const [err, setErr] = useState('')
  const load = useCallback(async () => {
    const { data, error } = await supabase.rpc('admin_list_users')
    if (error) setErr(error.message)
    else setRows(data)
  }, [])
  useEffect(() => {
    load()
  }, [load])
  return (
    <>
      <p className="muted">
        Create accounts in the Supabase dashboard (Authentication, Users, Add user). The account appears here as a viewer. Give it a role, then ask the person to set their signature and PIN on their profile.
      </p>
      {err && <p className="error">{err}</p>}
      {rows.map((u) => <UserRow key={u.id} u={u} onSaved={load} />)}
    </>
  )
}

function UserRow({ u, onSaved }) {
  const [name, setName] = useState(u.full_name)
  const [role, setRole] = useState(u.role)
  const [active, setActive] = useState(u.active)
  const [msg, setMsg] = useState('')
  async function save() {
    setMsg('')
    const { error } = await supabase.rpc('admin_update_user', { p_user: u.id, p_name: name, p_role: role, p_active: active })
    if (error) setMsg(error.message)
    else {
      setMsg('Saved.')
      onSaved()
    }
  }
  async function resetPin() {
    if (!window.confirm(`Reset the PIN for ${u.full_name}? They must set a new one before signing.`)) return
    const { error } = await supabase.rpc('admin_reset_pin', { p_user: u.id })
    setMsg(error ? error.message : 'PIN reset.')
    onSaved()
  }
  return (
    <div className="card">
      <div className="muted">{u.email} · {u.has_pin ? 'PIN set' : 'no PIN'} · {u.has_signature ? 'signature saved' : 'no signature'}{u.last_sign_in_at ? ` · last sign in ${fmtDate(u.last_sign_in_at)}` : ''}</div>
      <div className="grid2">
        <div><label>Name</label><input value={name} onChange={(e) => setName(e.target.value)} maxLength={120} /></div>
        <div>
          <label>Role</label>
          <select value={role} onChange={(e) => setRole(e.target.value)}>
            {ROLES.map((r) => <option key={r} value={r}>{roleName(r)}</option>)}
          </select>
        </div>
        <div>
          <label>Status</label>
          <select value={active ? 'on' : 'off'} onChange={(e) => setActive(e.target.value === 'on')}>
            <option value="on">Active</option>
            <option value="off">Deactivated</option>
          </select>
        </div>
      </div>
      <div className="row" style={{ marginTop: '.5rem' }}>
        <button onClick={save}>Save</button>
        <button className="secondary" onClick={resetPin}>Reset PIN</button>
        {msg && <span className={msg === 'Saved.' || msg === 'PIN reset.' ? 'ok' : 'error'}>{msg}</span>}
      </div>
    </div>
  )
}

function Items() {
  const [rows, setRows] = useState([])
  const [f, setF] = useState({ sku: '', barcode: '', name: '', unit: 'ea', tracks_serials: false })
  const [err, setErr] = useState('')
  const load = useCallback(async () => {
    const { data, error } = await supabase.from('items').select('id, sku, barcode, name, unit, active, tracks_serials').order('sku').limit(5000)
    if (error) setErr(error.message)
    else setRows(data)
  }, [])
  useEffect(() => {
    load()
  }, [load])
  async function add(e) {
    e.preventDefault()
    setErr('')
    const { error } = await supabase.from('items').insert({
      sku: f.sku.trim(),
      barcode: f.barcode.trim() || null,
      name: f.name.trim(),
      unit: f.unit.trim() || 'ea',
      tracks_serials: f.tracks_serials,
    })
    if (error) return setErr(error.message)
    setF({ sku: '', barcode: '', name: '', unit: 'ea', tracks_serials: false })
    load()
  }
  async function toggle(it) {
    const { error } = await supabase.from('items').update({ active: !it.active }).eq('id', it.id)
    if (error) setErr(error.message)
    else load()
  }
  async function toggleSerials(it) {
    setErr('')
    const { error } = await supabase.from('items').update({ tracks_serials: !it.tracks_serials }).eq('id', it.id)
    if (error) setErr(error.message)
    else load()
  }
  return (
    <>
      <form className="card" onSubmit={add}>
        <div className="grid2">
          <div><label>SKU</label><input required maxLength={64} value={f.sku} onChange={(e) => setF({ ...f, sku: e.target.value })} /></div>
          <div><label>Barcode</label><input maxLength={64} value={f.barcode} onChange={(e) => setF({ ...f, barcode: e.target.value })} /></div>
          <div><label>Name</label><input required maxLength={200} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></div>
          <div><label>Unit</label><input maxLength={16} value={f.unit} onChange={(e) => setF({ ...f, unit: e.target.value })} /></div>
        </div>
        <label className="row">
          <input type="checkbox" style={{ width: 'auto' }} checked={f.tracks_serials} onChange={(e) => setF({ ...f, tracks_serials: e.target.checked })} />
          Each unit has its own serial number (laptops, phones, tools)
        </label>
        <p><button type="submit">Add item</button></p>
        {err && <p className="error">{err}</p>}
      </form>
      <div className="card tablewrap">
        <table>
          <thead><tr><th>SKU</th><th>Barcode</th><th>Name</th><th>Unit</th><th>Serial numbers</th><th /></tr></thead>
          <tbody>
            {rows.map((i) => (
              <tr key={i.id} style={i.active ? undefined : { opacity: 0.5 }}>
                <td>{i.sku}</td><td>{i.barcode}</td><td>{i.name}</td><td>{i.unit}</td>
                <td><button className="secondary" onClick={() => toggleSerials(i)}>{i.tracks_serials ? 'Tracked · turn off' : 'Off · turn on'}</button></td>
                <td><button className="secondary" onClick={() => toggle(i)}>{i.active ? 'Deactivate' : 'Activate'}</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  )
}

function Storerooms() {
  const [rows, setRows] = useState([])
  const [f, setF] = useState({ code: '', name: '' })
  const [err, setErr] = useState('')
  const load = useCallback(async () => {
    const { data, error } = await supabase.from('storerooms').select('id, code, name, active').order('code')
    if (error) setErr(error.message)
    else setRows(data)
  }, [])
  useEffect(() => {
    load()
  }, [load])
  async function add(e) {
    e.preventDefault()
    setErr('')
    const { error } = await supabase.from('storerooms').insert({ code: f.code.trim().toUpperCase(), name: f.name.trim() })
    if (error) return setErr(error.message)
    setF({ code: '', name: '' })
    load()
  }
  async function toggle(s) {
    const { error } = await supabase.from('storerooms').update({ active: !s.active }).eq('id', s.id)
    if (error) setErr(error.message)
    else load()
  }
  return (
    <>
      <form className="card" onSubmit={add}>
        <div className="grid2">
          <div><label>Code</label><input required maxLength={20} value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} /></div>
          <div><label>Name</label><input required maxLength={120} value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></div>
        </div>
        <p><button type="submit">Add storeroom</button></p>
        {err && <p className="error">{err}</p>}
      </form>
      <div className="card tablewrap">
        <table>
          <thead><tr><th>Code</th><th>Name</th><th /></tr></thead>
          <tbody>
            {rows.map((s) => (
              <tr key={s.id} style={s.active ? undefined : { opacity: 0.5 }}>
                <td>{s.code}</td><td>{s.name}</td>
                <td><button className="secondary" onClick={() => toggle(s)}>{s.active ? 'Deactivate' : 'Activate'}</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  )
}

function Steps() {
  const [rows, setRows] = useState([])
  const [err, setErr] = useState('')
  const load = useCallback(async () => {
    const { data, error } = await supabase.from('signoff_steps').select('step_order, role, label').order('step_order')
    if (error) setErr(error.message)
    else setRows(data)
  }, [])
  useEffect(() => {
    load()
  }, [load])
  async function save(row) {
    setErr('')
    const { error } = await supabase.from('signoff_steps').upsert({ step_order: row.step_order, role: row.role, label: row.label.trim() })
    if (error) setErr(error.message)
    else load()
  }
  async function remove(row) {
    if (!window.confirm(`Remove step ${row.step_order}?`)) return
    const { error } = await supabase.from('signoff_steps').delete().eq('step_order', row.step_order)
    if (error) setErr(error.message)
    else load()
  }
  function addStep() {
    const n = rows.length ? Math.max(...rows.map((r) => r.step_order)) + 1 : 1
    setRows([...rows, { step_order: n, role: 'dispatch_manager', label: 'New step', fresh: true }])
  }
  return (
    <>
      <p className="muted">
        The person who prepares a movement always signs first (step 0). These steps follow, in order. Changes apply to movements submitted after the change. A gate pass is issued when the last step is signed.
      </p>
      {err && <p className="error">{err}</p>}
      {rows.map((r, idx) => (
        <div className="card" key={r.step_order}>
          <div className="grid2">
            <div><label>Step {r.step_order}</label>
              <input value={r.label} maxLength={60} onChange={(e) => setRows(rows.map((x, i) => (i === idx ? { ...x, label: e.target.value } : x)))} /></div>
            <div><label>Role that signs</label>
              <select value={r.role} onChange={(e) => setRows(rows.map((x, i) => (i === idx ? { ...x, role: e.target.value } : x)))}>
                {STEP_ROLES.map((x) => <option key={x} value={x}>{roleName(x)}</option>)}
              </select></div>
          </div>
          <div className="row" style={{ marginTop: '.5rem' }}>
            <button onClick={() => save(r)}>Save</button>
            {!r.fresh && <button className="secondary" onClick={() => remove(r)}>Remove</button>}
          </div>
        </div>
      ))}
      <button className="secondary" onClick={addStep}>Add a step</button>
    </>
  )
}

function Audit() {
  const [rows, setRows] = useState([])
  const [names, setNames] = useState({})
  const [err, setErr] = useState('')
  useEffect(() => {
    Promise.all([
      supabase.from('audit_log').select('id, at, actor, action, table_name, record_id').order('id', { ascending: false }).limit(200),
      supabase.from('profiles').select('id, full_name'),
    ]).then(([a, p]) => {
      if (a.error) return setErr(a.error.message)
      setRows(a.data)
      setNames(Object.fromEntries((p.data || []).map((x) => [x.id, x.full_name])))
    })
  }, [])
  return (
    <>
      {err && <p className="error">{err}</p>}
      <div className="card tablewrap">
        <table>
          <thead><tr><th>When</th><th>Who</th><th>Action</th><th>Table</th><th>Record</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>{fmtDate(r.at)}</td>
                <td>{names[r.actor] || (r.actor ? r.actor.slice(0, 8) : 'system')}</td>
                <td>{r.action}</td><td>{r.table_name}</td><td className="muted">{r.record_id.slice(0, 8)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  )
}
