import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { supabase } from '../supabase.js'
import SignatureImg from '../components/SignatureImg.jsx'
import SerialList from '../components/SerialList.jsx'
import { useAuth } from '../auth.jsx'
import { PREPARERS, TYPE, fmtDate, fmtQty, one } from '../fmt.js'

const FIELD = { counterparty: 'Supplier / customer', delivery_address: 'Delivery address', vehicle_reg: 'Vehicle', driver_name: 'Driver', notes: 'Notes' }

export default function DeliveryNote() {
  const { id } = useParams()
  const { profile } = useAuth()
  const role = profile.role
  const [dn, setDn] = useState(null)
  const [err, setErr] = useState('')

  useEffect(() => {
    supabase
      .from('delivery_notes')
      .select('number, issued_at, snapshot, movement:movements(id, status, counterparty, delivery_address, vehicle_reg, driver_name, notes, content_hash, edits:movement_edits(id, at, kind, changes, actor:profiles!actor(full_name)), signoffs(step_order, step_label, signed_at, signature_path, user:profiles!user_id(full_name)))')
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
  // Details can be amended after the note is issued, so they are read live. Items stay as issued.
  const d = {
    counterparty: mv?.counterparty,
    address: mv?.delivery_address,
    vehicle: mv?.vehicle_reg,
    driver: mv?.driver_name,
    notes: mv?.notes,
  }
  const edits = [...(mv?.edits || [])].filter((e) => e.kind === 'details').sort((a, b) => a.id - b.id)
  const sign = [...(mv?.signoffs || [])].sort((a, b) => a.step_order - b.step_order)

  return (
    <>
      <div className="row no-print" style={{ marginBottom: '1rem' }}>
        <Link to={`/movements/${id}`}><button className="secondary">Back</button></Link>
        {PREPARERS.includes(role) && ['pending_signoff', 'signed_off'].includes(mv?.status) && (
          <Link to={`/movements/${id}`} state={{ edit: true }}><button className="secondary">Edit details</button></Link>
        )}
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
            {d.counterparty && <tr><th>Supplier / customer</th><td>{d.counterparty}</td></tr>}
            {d.address && <tr><th>Delivery address</th><td style={{ whiteSpace: 'pre-line' }}>{d.address}</td></tr>}
            {d.vehicle && <tr><th>Vehicle</th><td>{d.vehicle}</td></tr>}
            {d.driver && <tr><th>Driver</th><td>{d.driver}</td></tr>}
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
        {d.notes && <p><strong>Notes:</strong> {d.notes}</p>}
        {edits.length > 0 && (
          <>
            <h2>Amendments</h2>
            <table>
              <tbody>
                {edits.map((e) => (
                  <tr key={e.id}>
                    <td>{fmtDate(e.at)}<div className="muted">{one(e.actor)?.full_name}</div></td>
                    <td>
                      {Object.entries(e.changes || {}).map(([k, v]) => (
                        <div key={k}>{FIELD[k] || k}: {v.from || 'empty'} → {v.to || 'empty'}</div>
                      ))}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}
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
        <p className="muted" style={{ marginTop: '1.5rem' }}>Integrity code {(mv?.content_hash || s.content_hash)?.slice(0, 16)}</p>
      </div>
    </>
  )
}
