import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import QRCode from 'qrcode'
import { supabase } from '../supabase.js'
import SerialList from '../components/SerialList.jsx'
import { TYPE, fmtDate, fmtQty, one } from '../fmt.js'

export default function GatePass() {
  const { id } = useParams()
  const [gp, setGp] = useState(null)
  const [qr, setQr] = useState('')
  const [err, setErr] = useState('')

  useEffect(() => {
    supabase
      .from('gate_passes')
      .select('number, code, status, issued_at, used_at, movement:movements(ref, type, vehicle_reg, driver_name, counterparty, lines:movement_lines(qty, item:items(id, sku, name, unit)), serials:movement_serials(item_id, serial))')
      .eq('movement_id', id)
      .maybeSingle()
      .then(async ({ data, error }) => {
        if (error) return setErr(error.message)
        if (!data) return setErr('No gate pass yet. It is issued when every sign off is complete.')
        setGp(data)
        setQr(await QRCode.toDataURL(data.code, { margin: 1, width: 440, errorCorrectionLevel: 'M' }))
      })
  }, [id])

  if (err) return <p className="error">{err}</p>
  if (!gp) return <p className="center">Loading…</p>
  const mv = one(gp.movement)

  return (
    <>
      <div className="row no-print" style={{ marginBottom: '1rem' }}>
        <Link to={`/movements/${id}`}><button className="secondary">Back</button></Link>
        <button onClick={() => window.print()}>Print</button>
      </div>
      <div className="doc">
        <h1>Gate pass {gp.number}</h1>
        <p>
          <span className={`badge ${gp.status}`}>{gp.status === 'issued' ? 'Cleared for the gate' : 'Already used'}</span>
          {' '}Issued {fmtDate(gp.issued_at)}
          {gp.used_at && ` · Used ${fmtDate(gp.used_at)}`}
        </p>
        <div className="row" style={{ alignItems: 'flex-start', gap: '1.5rem' }}>
          {qr && <img className="qr" src={qr} alt="Gate pass QR code" />}
          <div>
            <p><strong>{TYPE[mv.type]}</strong> · {mv.ref}</p>
            {mv.counterparty && <p>{mv.counterparty}</p>}
            {mv.vehicle_reg && <p>Vehicle {mv.vehicle_reg}</p>}
            {mv.driver_name && <p>Driver {mv.driver_name}</p>}
          </div>
        </div>
        <h2>Checked and signed off</h2>
        <table>
          <thead><tr><th>SKU</th><th>Description</th><th className="num">Quantity</th></tr></thead>
          <tbody>
            {[...(mv.lines || [])].sort((a, b) => a.item.sku.localeCompare(b.item.sku)).map((l) => (
              <tr key={l.item.sku}><td>{l.item.sku}</td><td>{l.item.name}<SerialList serials={(mv.serials || []).filter((x) => x.item_id === l.item.id).map((x) => x.serial).sort()} /></td><td className="num">{fmtQty(l.qty)} {l.item.unit}</td></tr>
            ))}
          </tbody>
        </table>
        <p className="muted">The guard scans this code once. A pass cannot be used twice.</p>
        <p className="muted" style={{ fontFamily: 'monospace', wordBreak: 'break-all' }}>Manual entry code: {gp.code}</p>
      </div>
    </>
  )
}
