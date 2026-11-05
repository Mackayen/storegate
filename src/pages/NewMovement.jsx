import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '../supabase.js'
import ScanInput from '../components/ScanInput.jsx'
import { fmtQty } from '../fmt.js'

// The serial numbers for one line. Receiving: optional, they can also be added later.
// Dispatch and transfer: every unit that leaves must be scanned, and the quantity follows the scans.
function SerialPanel({ line, leaving, onAdd, onRemove }) {
  return (
    <div className="serialpanel">
      <div className="muted">
        {leaving
          ? `Scan each unit leaving. ${line.serials.length} scanned.`
          : `Serial numbers (optional now, can be added later). ${line.serials.length} of ${Number(line.qty) || 0}.`}
      </div>
      <ScanInput
        autoFocus={false}
        onScan={onAdd}
        placeholder={`Scan a ${line.item.sku} serial number`}
      />
      <div className="chips">
        {line.serials.map((x) => (
          <span key={x} className="chip">
            {x}
            <button type="button" className="link" aria-label={`Remove ${x}`} onClick={() => onRemove(x)}>×</button>
          </span>
        ))}
      </div>
    </div>
  )
}

export default function NewMovement() {
  const nav = useNavigate()
  const [items, setItems] = useState([])
  const [rooms, setRooms] = useState([])
  const [avail, setAvail] = useState({})
  const [index, setIndex] = useState({}) // serials in stock at the source: lower(serial) -> { item_id, serial }
  const [type, setType] = useState('receive')
  const [fromId, setFromId] = useState('')
  const [toId, setToId] = useState('')
  const [counterparty, setCounterparty] = useState('')
  const [vehicle, setVehicle] = useState('')
  const [driver, setDriver] = useState('')
  const [notes, setNotes] = useState('')
  const [lines, setLines] = useState([])
  const [pick, setPick] = useState('')
  const [msg, setMsg] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    Promise.all([
      supabase.from('items').select('id, sku, barcode, name, unit, tracks_serials').eq('active', true).order('name').limit(5000),
      supabase.from('storerooms').select('id, code, name').eq('active', true).order('code'),
    ]).then(([i, s]) => {
      if (i.error || s.error) setErr((i.error || s.error).message)
      else {
        setItems(i.data)
        setRooms(s.data)
      }
    })
  }, [])

  // Show what is available in the source storeroom so the storeman sees problems early.
  useEffect(() => {
    if (type === 'receive' || !fromId) {
      setAvail({})
      setIndex({})
      return
    }
    supabase
      .from('stock_units')
      .select('item_id, serial')
      .eq('storeroom_id', fromId)
      .eq('status', 'in_stock')
      .eq('damaged', false)
      .limit(20000)
      .then(({ data }) => setIndex(Object.fromEntries((data || []).map((r) => [r.serial.toLowerCase(), r]))))
    supabase
      .from('stock_levels')
      .select('item_id, qty')
      .eq('storeroom_id', fromId)
      .then(({ data }) => setAvail(Object.fromEntries((data || []).map((r) => [r.item_id, Number(r.qty)]))))
  }, [type, fromId])

  // Units leaving a storeroom are always chosen by serial number, so their serials belong to one
  // storeroom and one movement type. When either changes, the serials are cleared.
  useEffect(() => {
    setLines((prev) => prev.map((l) => (l.item.tracks_serials ? { ...l, serials: [], qty: type === 'receive' ? l.qty : '0' } : l)))
  }, [type, fromId])

  const leaving = type !== 'receive'

  function addItem(item) {
    setMsg('')
    setLines((prev) => {
      const hit = prev.find((l) => l.item.id === item.id)
      if (hit) {
        if (item.tracks_serials && leaving) return prev
        return prev.map((l) => (l === hit ? { ...l, qty: String((Number(l.qty) || 0) + 1) } : l))
      }
      if (item.tracks_serials && leaving) return [...prev, { item, qty: '0', serials: [] }]
      return [...prev, { item, qty: '1', serials: [] }]
    })
  }

  // Add one serial number to the line of its item.
  function addSerial(item, raw) {
    const serial = raw.trim()
    if (!serial) return
    setMsg('')
    if (leaving) {
      const known = index[serial.toLowerCase()]
      if (!known || known.item_id !== item.id) return setMsg(`"${serial}" is not an undamaged ${item.sku} in stock here.`)
    }
    setLines((prev) => {
      if (prev.some((l) => l.serials.some((x) => x.toLowerCase() === serial.toLowerCase()))) {
        setMsg(`"${serial}" is already on this movement.`)
        return prev
      }
      return prev.map((l) => {
        if (l.item.id !== item.id) return l
        const serials = [...l.serials, serial]
        const qty = leaving ? String(serials.length) : String(Math.max(Number(l.qty) || 0, serials.length))
        return { ...l, serials, qty }
      })
    })
  }

  function removeSerial(item, serial) {
    setLines((prev) =>
      prev.map((l) => {
        if (l.item.id !== item.id) return l
        const serials = l.serials.filter((x) => x !== serial)
        return { ...l, serials, qty: leaving ? String(serials.length) : l.qty }
      }),
    )
  }

  function onScan(code) {
    const c = code.toLowerCase()
    const hit = items.find((i) => (i.barcode && i.barcode.toLowerCase() === c) || i.sku.toLowerCase() === c)
    if (hit) return addItem(hit)
    const unit = leaving ? index[c] : null
    if (unit) {
      const it = items.find((i) => i.id === unit.item_id)
      if (it) {
        setLines((prev) => (prev.some((l) => l.item.id === it.id) ? prev : [...prev, { item: it, qty: '0', serials: [] }]))
        return addSerial(it, unit.serial)
      }
    }
    setMsg(leaving && !fromId ? 'Choose the source storeroom first, then scan.' : `No active item or serial number with code "${code}".`)
  }

  async function save(e) {
    e.preventDefault()
    setErr('')
    if (!lines.length) return setErr('Add at least one item.')
    const payload = []
    for (const l of lines) {
      const qty = Number(l.qty)
      if (!Number.isFinite(qty) || qty <= 0) {
        return setErr(l.item.tracks_serials && leaving ? `Scan the serial number of every ${l.item.sku} that is leaving.` : 'Every quantity must be greater than zero.')
      }
      if (l.item.tracks_serials && !Number.isInteger(qty)) return setErr(`${l.item.sku} is counted in whole units.`)
      if (l.item.tracks_serials && l.serials.length > qty) return setErr(`${l.item.sku} has more serial numbers than units.`)
      const line = { item_id: l.item.id, qty }
      if (l.item.tracks_serials && l.serials.length) line.serials = l.serials
      payload.push(line)
    }
    if (type !== 'receive' && !fromId) return setErr('Choose the source storeroom.')
    if (type !== 'dispatch' && !toId) return setErr('Choose the destination storeroom.')
    setBusy(true)
    const { data, error } = await supabase.rpc('create_movement', {
      p_type: type,
      p_from: type === 'receive' ? null : fromId,
      p_to: type === 'dispatch' ? null : toId,
      p_counterparty: counterparty,
      p_vehicle: vehicle,
      p_driver: driver,
      p_notes: notes,
      p_lines: payload,
    })
    setBusy(false)
    if (error) return setErr(error.message)
    nav(`/movements/${data}`)
  }

  return (
    <>
      <h1>New movement</h1>
      <form onSubmit={save}>
        <div className="card">
          <div className="grid2">
            <div>
              <label htmlFor="type">Type</label>
              <select id="type" value={type} onChange={(e) => setType(e.target.value)}>
                <option value="receive">Receive stock in</option>
                <option value="dispatch">Dispatch stock out</option>
                <option value="transfer">Transfer between storerooms</option>
              </select>
            </div>
            {type !== 'receive' && (
              <div>
                <label htmlFor="from">From storeroom</label>
                <select id="from" value={fromId} onChange={(e) => setFromId(e.target.value)}>
                  <option value="">Choose…</option>
                  {rooms.map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                </select>
              </div>
            )}
            {type !== 'dispatch' && (
              <div>
                <label htmlFor="to">To storeroom</label>
                <select id="to" value={toId} onChange={(e) => setToId(e.target.value)}>
                  <option value="">Choose…</option>
                  {rooms.map((r) => <option key={r.id} value={r.id}>{r.code} · {r.name}</option>)}
                </select>
              </div>
            )}
            <div>
              <label htmlFor="cp">{type === 'receive' ? 'Supplier' : type === 'dispatch' ? 'Customer or destination' : 'Reference'}</label>
              <input id="cp" value={counterparty} onChange={(e) => setCounterparty(e.target.value)} maxLength={200} />
            </div>
            <div>
              <label htmlFor="veh">Vehicle registration</label>
              <input id="veh" value={vehicle} onChange={(e) => setVehicle(e.target.value)} maxLength={30} />
            </div>
            <div>
              <label htmlFor="drv">Driver name</label>
              <input id="drv" value={driver} onChange={(e) => setDriver(e.target.value)} maxLength={120} />
            </div>
          </div>
          <label htmlFor="notes">Notes</label>
          <textarea id="notes" value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={1000} />
        </div>

        <div className="card">
          <h3>Items</h3>
          <ScanInput onScan={onScan} placeholder="Scan an item barcode or type a SKU, then press Enter" />
          <div className="row">
            <select value={pick} onChange={(e) => setPick(e.target.value)} aria-label="Pick an item" style={{ flex: 1 }}>
              <option value="">Or pick an item…</option>
              {items.map((i) => <option key={i.id} value={i.id}>{i.sku} · {i.name}</option>)}
            </select>
            <button
              type="button"
              className="secondary"
              onClick={() => {
                const it = items.find((i) => i.id === pick)
                if (it) addItem(it)
                setPick('')
              }}
            >
              Add
            </button>
          </div>
          {msg && <p className="error">{msg}</p>}
          <div className="tablewrap">
            <table>
              <thead><tr><th>Item</th>{type !== 'receive' && <th className="num">Available</th>}<th className="num">Qty</th><th /></tr></thead>
              <tbody>
                {lines.map((l) => {
                  const have = avail[l.item.id] ?? 0
                  const over = type !== 'receive' && fromId && Number(l.qty) > have
                  const byScan = l.item.tracks_serials && leaving
                  return (
                    <tr key={l.item.id}>
                      <td>
                        {l.item.sku}<div className="muted">{l.item.name}</div>
                        {l.item.tracks_serials && (
                          <SerialPanel
                            line={l}
                            leaving={leaving}
                            onAdd={(v) => addSerial(l.item, v)}
                            onRemove={(v) => removeSerial(l.item, v)}
                          />
                        )}
                      </td>
                      {type !== 'receive' && <td className="num" style={over ? { color: 'var(--bad)' } : undefined}>{fmtQty(have)}</td>}
                      <td className="num">
                        <input
                          type="number" min="0" step={l.item.tracks_serials ? '1' : 'any'} value={l.qty} readOnly={byScan}
                          aria-label={`Quantity for ${l.item.sku}`}
                          onChange={(e) => setLines((p) => p.map((x) => (x === l ? { ...x, qty: e.target.value } : x)))}
                        />
                      </td>
                      <td><button type="button" className="secondary" onClick={() => setLines((p) => p.filter((x) => x !== l))}>Remove</button></td>
                    </tr>
                  )
                })}
                {!lines.length && <tr><td colSpan={4} className="muted">Nothing added yet.</td></tr>}
              </tbody>
            </table>
          </div>
        </div>

        {err && <p className="error">{err}</p>}
        <button type="submit" disabled={busy}>{busy ? 'Saving…' : 'Save as draft'}</button>
        <p className="muted">After saving you review the draft, then submit it with your PIN. That creates the delivery note and starts sign off.</p>
      </form>
    </>
  )
}
