import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../supabase.js'
import { LEDGER_KIND, TYPE, fmtDate, fmtQty } from '../fmt.js'

export default function Ledger() {
  const [rows, setRows] = useState([])
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase
      .from('stock_ledger')
      .select('id, created_at, delta, balance_after, movement_id, kind, note, unit:stock_units(id, serial), item:items(sku, name), storeroom:storerooms(code), movement:movements(ref, type)')
      .order('id', { ascending: false })
      .limit(300)
      .then(({ data, error }) => {
        if (error) setErr(error.message)
        else setRows(data)
        setLoading(false)
      })
  }, [])

  return (
    <>
      <h1>Stock history</h1>
      <p className="muted">Every change to stock, newest first. Entries cannot be edited or deleted.</p>
      {err && <p className="error">{err}</p>}
      <div className="card tablewrap">
        <table>
          <thead><tr><th>When</th><th>Movement</th><th>Storeroom</th><th>Item</th><th className="num">Change</th><th className="num">Balance</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td>{fmtDate(r.created_at)}</td>
                <td>
                  {r.movement_id ? (
                    <>
                      <Link to={`/movements/${r.movement_id}`}>{r.movement?.ref}</Link>
                      <div className="muted">{TYPE[r.movement?.type]}</div>
                    </>
                  ) : (
                    <>
                      {LEDGER_KIND[r.kind] || r.kind}
                      {r.unit && <div className="muted"><Link to={`/units/${r.unit.id}`}>{r.unit.serial}</Link></div>}
                      {r.note && <div className="muted">{r.note}</div>}
                    </>
                  )}
                </td>
                <td>{r.storeroom?.code}</td>
                <td>{r.item?.sku}<div className="muted">{r.item?.name}</div></td>
                <td className="num" style={{ color: r.delta < 0 ? 'var(--bad)' : 'var(--good)' }}>{r.delta > 0 ? '+' : ''}{fmtQty(r.delta)}</td>
                <td className="num">{fmtQty(r.balance_after)}</td>
              </tr>
            ))}
            {!loading && rows.length === 0 && <tr><td colSpan={6} className="muted">No stock changes yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  )
}
