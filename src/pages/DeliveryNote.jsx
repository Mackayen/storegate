import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { supabase } from '../supabase.js'
import SignatureImg from '../components/SignatureImg.jsx'
import SerialList from '../components/SerialList.jsx'
import { TYPE, fmtDate, fmtQty, one } from '../fmt.js'

export default function DeliveryNote() {
  const { id } = useParams()
  const [dn, setDn] = useState(null)
  const [err, setErr] = useState('')

  useEffect(() => {
    supabase
      .from('delivery_notes')
      .select('number, issued_at, snapshot, movement:movements(id, status, signoffs(step_order, step_label, signed_at, signature_path, user:profiles!user_id(full_name)))')
      .eq('movement_id', id)
      .maybeSingle()
      .then(({ data, error }) => {
        if (error) setErr(error.message)
        else if (!data) setErr('No delivery note for this movement yet.')
        else setDn(data)
      })
  }, [id])

  if (err) return <p className="error">{err}</p>
  if (!dn) return <p className="center">Loading…</p>

  const s = dn.snapshot
  const mv = one(dn.movement)
  const sign = [...(mv?.signoffs || [])].sort((a, b) => a.step_order - b.step_order)

  return (
    <>
      <div className="row no-print" style={{ marginBottom: '1rem' }}>
        <Link to={`/movements/${id}`}><button className="secondary">Back</button></Link>
        <button onClick={() => window.print()}>Print</button>
      </div>
      <div className="doc">
        <h1>Delivery note {dn.number}</h1>
        <p>
          {TYPE[s.type]} · {s.movement_ref} · Issued {fmtDate(dn.issued_at)}
          {mv?.status !== 'signed_off' && <strong> · NOT YET FULLY SIGNED OFF</strong>}
        </p>
        <table>
          <tbody>
            {s.from && <tr><th>From</th><td>{s.from.code} · {s.from.name}</td></tr>}
            {s.to && <tr><th>To</th><td>{s.to.code} · {s.to.name}</td></tr>}
            {s.counterparty && <tr><th>Supplier / customer</th><td>{s.counterparty}</td></tr>}
            {s.vehicle_reg && <tr><th>Vehicle</th><td>{s.vehicle_reg}</td></tr>}
            {s.driver_name && <tr><th>Driver</th><td>{s.driver_name}</td></tr>}
            <tr><th>Prepared by</th><td>{s.prepared_by}</td></tr>
          </tbody>
        </table>
        <h2>Items</h2>
        <table>
          <thead><tr><th>SKU</th><th>Description</th><th className="num">Quantity</th></tr></thead>
          <tbody>
            {(s.lines || []).map((l) => (
              <tr key={l.sku}><td>{l.sku}</td><td>{l.name}<SerialList serials={l.serials} /></td><td className="num">{fmtQty(l.qty)} {l.unit}</td></tr>
            ))}
          </tbody>
        </table>
        {s.notes && <p><strong>Notes:</strong> {s.notes}</p>}
        <h2>Signatures</h2>
        <div className="grid2">
          {sign.map((x) => (
            <div key={x.step_order}>
              <div className="muted">{x.step_label}</div>
              <SignatureImg path={x.signature_path} height={56} />
              <div>{x.user?.full_name}</div>
              <div className="muted">{fmtDate(x.signed_at)}</div>
            </div>
          ))}
        </div>
        <p className="muted" style={{ marginTop: '1.5rem' }}>Integrity code {s.content_hash?.slice(0, 16)}</p>
      </div>
    </>
  )
}
