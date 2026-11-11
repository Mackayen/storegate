import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../supabase.js'
import { fmtQty } from '../fmt.js'

export default function Dashboard() {
  const [rows, setRows] = useState([])
  const [rooms, setRooms] = useState([])
  const [room, setRoom] = useState('')
  const [q, setQ] = useState('')
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.from('storerooms').select('id, code, name').eq('active', true).order('code').then(({ data }) => setRooms(data || []))
  }, [])

  // The search runs in the database with bound parameters. Nothing typed here is built into SQL.
  useEffect(() => {
    let off = false
    async function load() {
      const { data, error } = await supabase.rpc('stock_piles', { p_query: q.trim() || null, p_storeroom: room || null })
      if (off) return
      if (error) setErr(error.message)
      else {
        setErr('')
        setRows(data)
      }
      setLoading(false)
    }
    const t = setTimeout(load, 250)
    const channel = supabase
      .channel('stock-' + Math.random().toString(36).slice(2))
      .on('postgres_changes', { event: '*', schema: 'public', table: 'stock_levels' }, load)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'stock_units' }, load)
      .subscribe()
    return () => {
      off = true
      clearTimeout(t)
      supabase.removeChannel(channel)
    }
  }, [q, room])

  const notWorking = rows.reduce((n, r) => n + (r.damaged || 0), 0)

  return (
    <>
      <h1>Stock on hand</h1>
      <div className="card">
        <div className="grid2">
          <div>
            <label htmlFor="room">Storeroom</label>
            <select id="room" value={room} onChange={(e) => setRoom(e.target.value)}>
              <option value="">All storerooms</option>
              {rooms.map((r) => (
                <option key={r.id} value={r.id}>{r.code} · {r.name}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="q">Search by name, SKU, barcode or serial number</label>
            <input id="q" value={q} onChange={(e) => setQ(e.target.value)} maxLength={64} />
          </div>
        </div>
        <p className="muted">
          {notWorking > 0 ? <span className="bad">{notWorking} not working</span> : 'Nothing flagged as not working.'}{' '}
          <Link to="/search">Search every unit</Link>
        </p>
      </div>
      {err && <p className="error">{err}</p>}
      <div className="card tablewrap">
        <table>
          <thead>
            <tr><th>Storeroom</th><th>SKU</th><th>Item</th><th className="num">Quantity</th><th className="num">Not working</th></tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.storeroom_id + r.item_id} className={r.damaged > 0 ? 'damaged' : undefined}>
                <td>{r.storeroom_code}</td>
                <td>{r.sku}</td>
                <td>
                  {r.tracks_serials ? <Link to={`/search?q=${encodeURIComponent(r.sku)}&room=${r.storeroom_id}`}>{r.item_name}</Link> : r.item_name}
                  {r.tracks_serials && <div className="muted">{r.serialised} of {fmtQty(r.qty)} have a serial number</div>}
                </td>
                <td className="num">{fmtQty(r.qty)} {r.unit}</td>
                <td className={'num' + (r.damaged > 0 ? ' bad' : '')}>{r.tracks_serials ? r.damaged : '–'}</td>
              </tr>
            ))}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={5} className="muted">No stock to show.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  )
}
