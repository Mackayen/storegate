import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { supabase } from '../supabase.js'
import { useAuth } from '../auth.jsx'
import { UNIT_MANAGERS, fmtDate, one } from '../fmt.js'

const EVENT = {
  received: 'Received',
  serial_added: 'Serial number added',
  damaged: 'Flagged not working',
  repaired: 'Marked working',
  note: 'Note',
  dispatched: 'Dispatched',
  transferred: 'Transferred',
  written_off: 'Written off',
  replacement_added: 'Replacement added',
}

export default function UnitDetail() {
  const { id } = useParams()
  const { profile } = useAuth()
  const canManage = UNIT_MANAGERS.includes(profile.role)
  const [u, setU] = useState(null)
  const [events, setEvents] = useState([])
  const [replacement, setReplacement] = useState(null)
  const [text, setText] = useState('')
  const [serial, setSerial] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const [a, b, c] = await Promise.all([
      supabase
        .from('stock_units')
        .select('id, serial, status, damaged, note, created_at, item:items(sku, name), storeroom:storerooms(code, name), replaces:stock_units!replaces_unit_id(id, serial)')
        .eq('id', id)
        .maybeSingle(),
      supabase
        .from('unit_events')
        .select('id, at, kind, note, actor:profiles!actor(full_name), movement:movements(id, ref)')
        .eq('unit_id', id)
        .order('id', { ascending: false }),
      supabase.from('stock_units').select('id, serial').eq('replaces_unit_id', id).maybeSingle(),
    ])
    if (a.error || b.error) setErr((a.error || b.error).message)
    else {
      setU(a.data)
      setEvents(b.data)
      setReplacement(c.data)
    }
  }, [id])

  useEffect(() => {
    load()
  }, [load])

  async function run(fn, args, after) {
    setBusy(true)
    setErr('')
    const { error } = await supabase.rpc(fn, args)
    setBusy(false)
    if (error) return setErr(error.message)
    after?.()
    load()
  }

  if (!u) return err ? <p className="error">{err}</p> : <p className="muted">Loading…</p>
  const inStock = u.status === 'in_stock'
  const needText = () => {
    if (!text.trim()) {
      setErr('Write a note first.')
      return true
    }
    return false
  }

  return (
    <>
      <p><Link to="/search">← Search</Link></p>
      <h1>{u.serial}</h1>
      <div className={'card' + (inStock && u.damaged ? ' damaged' : '')} style={inStock && u.damaged ? { borderColor: 'var(--bad)', background: '#fee4e2' } : undefined}>
        <div className="row spread">
          <div>
            <strong>{u.item?.sku}</strong> · {u.item?.name}
            <div className="muted">{u.storeroom?.code} · {u.storeroom?.name}</div>
          </div>
          <span className={'badge ' + (inStock && u.damaged ? 'damaged' : u.status)}>
            {inStock ? (u.damaged ? 'Not working' : 'In stock') : u.status === 'written_off' ? 'Written off' : 'Dispatched'}
          </span>
        </div>
        {u.note && <p><strong>Note:</strong> {u.note}</p>}
        {u.replaces && <p className="muted">Replaces <Link to={`/units/${u.replaces.id}`}>{u.replaces.serial}</Link></p>}
        {replacement && <p className="muted">Replaced by <Link to={`/units/${replacement.id}`}>{replacement.serial}</Link></p>}
      </div>

      {canManage && inStock && (
        <div className="card">
          <h3>Update this unit</h3>
          <label htmlFor="un">Note or reason</label>
          <textarea id="un" value={text} onChange={(e) => setText(e.target.value)} maxLength={500} />
          <div className="row">
            {!u.damaged ? (
              <button type="button" className="danger" disabled={busy}
                onClick={() => !needText() && run('flag_unit', { p_unit: id, p_damaged: true, p_note: text }, () => setText(''))}>
                Flag as not working
              </button>
            ) : (
              <button type="button" disabled={busy}
                onClick={() => !needText() && run('flag_unit', { p_unit: id, p_damaged: false, p_note: text }, () => setText(''))}>
                Mark as working
              </button>
            )}
            <button type="button" className="secondary" disabled={busy}
              onClick={() => !needText() && run('add_unit_note', { p_unit: id, p_note: text }, () => setText(''))}>
              Save note
            </button>
            <button type="button" className="danger" disabled={busy}
              onClick={() => {
                if (needText()) return
                if (window.confirm(`Write off ${u.serial}? It leaves stock and the reason is kept in the history.`))
                  run('write_off_unit', { p_unit: id, p_reason: text }, () => setText(''))
              }}>
              Write off
            </button>
          </div>
          <p className="muted">A note is required to flag a unit or write it off. A unit flagged as not working cannot be dispatched.</p>
        </div>
      )}

      {canManage && u.status === 'written_off' && !replacement && (
        <div className="card">
          <h3>Add a replacement</h3>
          <p className="muted">Adds one unit back to the same pile, linked to this one.</p>
          <label htmlFor="rs">New serial number</label>
          <input id="rs" value={serial} onChange={(e) => setSerial(e.target.value)} maxLength={64} />
          <label htmlFor="rn">Note</label>
          <input id="rn" value={text} onChange={(e) => setText(e.target.value)} maxLength={500} />
          <p>
            <button type="button" disabled={busy || !serial.trim()}
              onClick={() => run('add_replacement', { p_unit: id, p_serial: serial, p_note: text }, () => { setSerial(''); setText('') })}>
              Add replacement
            </button>
          </p>
        </div>
      )}
      {err && <p className="error">{err}</p>}

      <h2>History</h2>
      <div className="card tablewrap">
        <table>
          <thead><tr><th>When</th><th>What</th><th>By</th><th>Note</th></tr></thead>
          <tbody>
            {events.map((e) => (
              <tr key={e.id}>
                <td>{fmtDate(e.at)}</td>
                <td>
                  {EVENT[e.kind] || e.kind}
                  {e.movement && <div className="muted"><Link to={`/movements/${one(e.movement).id}`}>{one(e.movement).ref}</Link></div>}
                </td>
                <td>{one(e.actor)?.full_name}</td>
                <td>{e.note}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  )
}
