import { useCallback, useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { supabase } from '../supabase.js'
import { useAuth } from '../auth.jsx'
import ScanInput from '../components/ScanInput.jsx'
import { UNIT_MANAGERS, fmtQty } from '../fmt.js'

const STATES = [
  ['in_stock', 'In stock'],
  ['working', 'Working'],
  ['damaged', 'Not working'],
  ['written_off', 'Written off'],
  ['dispatched', 'Dispatched'],
  ['all', 'Everything'],
]
const STATE_LABEL = { in_stock: 'In stock', dispatched: 'Dispatched', written_off: 'Written off' }

// Add serial numbers to units that are already in a pile.
function AddSerials({ pile, onClose, onDone }) {
  const [list, setList] = useState([])
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  const slots = Math.max(0, Math.floor(Number(pile.unassigned)))

  function add(code) {
    setErr('')
    if (list.some((x) => x.toLowerCase() === code.toLowerCase())) return setErr(`"${code}" is already in the list.`)
    if (list.length >= slots) return setErr('Every unit in this pile already has a serial number.')
    setList((p) => [...p, code])
  }
  async function save() {
    setBusy(true)
    setErr('')
    const { error } = await supabase.rpc('add_serials', { p_storeroom: pile.storeroom_id, p_item: pile.item_id, p_serials: list })
    setBusy(false)
    if (error) return setErr(error.message)
    onDone()
  }
  return (
    <div className="modal" role="dialog" aria-modal="true" aria-label="Add serial numbers">
      <div className="card wide">
        <h3>Add serial numbers</h3>
        <p className="muted">{pile.sku} · {pile.storeroom_code}. {slots} unit{slots === 1 ? '' : 's'} still without a serial number.</p>
        <ScanInput onScan={add} placeholder="Scan or type a serial number, then press Enter" />
        <div className="chips">
          {list.map((x) => (
            <span key={x} className="chip">{x}<button type="button" className="link" aria-label={`Remove ${x}`} onClick={() => setList((p) => p.filter((y) => y !== x))}>×</button></span>
          ))}
        </div>
        {err && <p className="error">{err}</p>}
        <div className="row">
          <button type="button" disabled={busy || !list.length} onClick={save}>{busy ? 'Saving…' : `Save ${list.length}`}</button>
          <button type="button" className="secondary" onClick={onClose}>Cancel</button>
        </div>
      </div>
    </div>
  )
}

// Write off units that have no serial number, with a reason that is kept in the history.
function WriteOff({ pile, onClose, onDone }) {
  const [qty, setQty] = useState('1')
  const [reason, setReason] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)
  async function save(e) {
    e.preventDefault()
    setBusy(true)
    setErr('')
    const { error } = await supabase.rpc('write_off_stock', {
      p_storeroom: pile.storeroom_id, p_item: pile.item_id, p_qty: Number(qty), p_reason: reason,
    })
    setBusy(false)
    if (error) return setErr(error.message)
    onDone()
  }
  return (
    <div className="modal" role="dialog" aria-modal="true" aria-label="Write off stock">
      <form className="card wide" onSubmit={save}>
        <h3>Write off stock</h3>
        <p className="muted">{pile.sku} · {pile.storeroom_code}. For units with a serial number, open the unit and write it off there.</p>
        <label htmlFor="wq">Quantity</label>
        <input id="wq" type="number" min="0" step={pile.tracks_serials ? '1' : 'any'} value={qty} onChange={(e) => setQty(e.target.value)} />
        <label htmlFor="wr">Reason</label>
        <textarea id="wr" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} required />
        {err && <p className="error">{err}</p>}
        <div className="row">
          <button type="submit" className="danger" disabled={busy}>{busy ? 'Saving…' : 'Write off'}</button>
          <button type="button" className="secondary" onClick={onClose}>Cancel</button>
        </div>
      </form>
    </div>
  )
}

export default function Search() {
  const { profile } = useAuth()
  const canManage = UNIT_MANAGERS.includes(profile.role)
  const [params, setParams] = useSearchParams()
  const [q, setQ] = useState(params.get('q') || '')
  const [room, setRoom] = useState(params.get('room') || '')
  const [state, setState] = useState(params.get('state') || 'in_stock')
  const [rooms, setRooms] = useState([])
  const [piles, setPiles] = useState([])
  const [units, setUnits] = useState([])
  const [limit, setLimit] = useState(100)
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(true)
  const [dialog, setDialog] = useState(null)

  useEffect(() => {
    supabase.from('storerooms').select('id, code, name').order('code').then(({ data }) => setRooms(data || []))
  }, [])

  const load = useCallback(async () => {
    const needle = q.trim() || null
    const [p, u] = await Promise.all([
      supabase.rpc('stock_piles', { p_query: needle, p_storeroom: room || null }),
      supabase.rpc('stock_units_search', { p_query: needle, p_storeroom: room || null, p_state: state, p_limit: limit, p_offset: 0 }),
    ])
    if (p.error || u.error) setErr((p.error || u.error).message)
    else {
      setErr('')
      setPiles(p.data)
      setUnits(u.data)
    }
    setLoading(false)
  }, [q, room, state, limit])

  useEffect(() => {
    const t = setTimeout(load, 250)
    return () => clearTimeout(t)
  }, [load])

  useEffect(() => {
    const next = {}
    if (q.trim()) next.q = q.trim()
    if (room) next.room = room
    if (state !== 'in_stock') next.state = state
    setParams(next, { replace: true })
  }, [q, room, state, setParams])

  function done() {
    setDialog(null)
    load()
  }

  return (
    <>
      <h1>Search stock</h1>
      <div className="card">
        <label>Scan a serial number or barcode here</label>
        <ScanInput onScan={(c) => setQ(c)} keepFocus={false} autoFocus={false} placeholder="Scan or type, then press Enter" />
        <div className="grid2">
          <div>
            <label htmlFor="sq">Searching for</label>
            <input id="sq" value={q} onChange={(e) => setQ(e.target.value)} maxLength={64} placeholder="Everything" />
          </div>
          <div>
            <label htmlFor="sr">Storeroom</label>
            <select id="sr" value={room} onChange={(e) => setRoom(e.target.value)}>
              <option value="">All storerooms</option>
              {rooms.map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
            </select>
          </div>
          <div>
            <label htmlFor="ss">Units</label>
            <select id="ss" value={state} onChange={(e) => setState(e.target.value)}>
              {STATES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
            </select>
          </div>
        </div>
      </div>
      {err && <p className="error">{err}</p>}

      <h2>Piles</h2>
      <div className="card tablewrap">
        <table>
          <thead>
            <tr><th>Storeroom</th><th>SKU</th><th>Item</th><th className="num">Quantity</th><th className="num">Not working</th>{canManage && <th />}</tr>
          </thead>
          <tbody>
            {piles.map((r) => (
              <tr key={r.storeroom_id + r.item_id} className={r.damaged > 0 ? 'damaged' : undefined}>
                <td>{r.storeroom_code}</td>
                <td>{r.sku}</td>
                <td>
                  {r.item_name}
                  {r.tracks_serials && <div className="muted">{r.serialised} with a serial number, {fmtQty(r.unassigned)} without</div>}
                </td>
                <td className="num">{fmtQty(r.qty)} {r.unit}</td>
                <td className={'num' + (r.damaged > 0 ? ' bad' : '')}>{r.tracks_serials ? r.damaged : '–'}</td>
                {canManage && (
                  <td>
                    <div className="row">
                      {r.tracks_serials && Number(r.unassigned) > 0 && (
                        <button type="button" className="secondary" onClick={() => setDialog({ kind: 'serials', pile: r })}>Add serial numbers</button>
                      )}
                      {(!r.tracks_serials || Number(r.unassigned) > 0) && (
                        <button type="button" className="secondary" onClick={() => setDialog({ kind: 'writeoff', pile: r })}>Write off</button>
                      )}
                    </div>
                  </td>
                )}
              </tr>
            ))}
            {!loading && piles.length === 0 && <tr><td colSpan={canManage ? 6 : 5} className="muted">No stock matches.</td></tr>}
          </tbody>
        </table>
      </div>

      <h2>Units with a serial number</h2>
      <div className="card tablewrap">
        <table>
          <thead><tr><th>Serial</th><th>Item</th><th>Storeroom</th><th>Status</th><th>Note</th></tr></thead>
          <tbody>
            {units.map((u) => (
              <tr key={u.unit_id} className={u.status !== 'in_stock' ? 'gone' : u.damaged ? 'damaged' : undefined}>
                <td><Link to={`/units/${u.unit_id}`}>{u.serial}</Link></td>
                <td>{u.sku}<div className="muted">{u.item_name}</div></td>
                <td>{u.storeroom_code}</td>
                <td>
                  <span className={'badge ' + (u.status === 'in_stock' && u.damaged ? 'damaged' : u.status)}>
                    {u.status === 'in_stock' && u.damaged ? 'Not working' : STATE_LABEL[u.status]}
                  </span>
                  {u.status === 'written_off' && u.replaced && <div className="muted">Replaced</div>}
                </td>
                <td>{u.note}</td>
              </tr>
            ))}
            {!loading && units.length === 0 && <tr><td colSpan={5} className="muted">No units match.</td></tr>}
          </tbody>
        </table>
        {units.length >= limit && <p><button type="button" className="secondary" onClick={() => setLimit((n) => n + 100)}>Show more</button></p>}
      </div>

      {dialog?.kind === 'serials' && <AddSerials pile={dialog.pile} onClose={() => setDialog(null)} onDone={done} />}
      {dialog?.kind === 'writeoff' && <WriteOff pile={dialog.pile} onClose={() => setDialog(null)} onDone={done} />}
    </>
  )
}
