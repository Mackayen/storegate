import { useState } from 'react'
import { supabase } from '../supabase.js'
import SerialList from '../components/SerialList.jsx'
import ScanInput from '../components/ScanInput.jsx'
import { TYPE, fmtDate, fmtQty } from '../fmt.js'

export default function Gate() {
  const [code, setCode] = useState('')
  const [result, setResult] = useState(null)
  const [released, setReleased] = useState(false)
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  async function scan(value) {
    setErr('')
    setReleased(false)
    setResult(null)
    const c = value.trim().toLowerCase()
    setCode(c)
    if (!/^[0-9a-f]{32}$/.test(c)) return setResult({ found: false })
    const { data, error } = await supabase.rpc('verify_gate_pass', { p_code: c })
    if (error) return setErr(error.message)
    setResult(data)
  }

  async function release() {
    setBusy(true)
    const { data, error } = await supabase.rpc('release_gate_pass', { p_code: code })
    setBusy(false)
    if (error) return setErr(error.message)
    if (!data?.ok) return setErr('This pass can no longer be released.')
    await scan(code)
    setReleased(true)
  }

  const r = result
  return (
    <>
      <h1>Gate check</h1>
      <ScanInput onScan={scan} placeholder="Scan the gate pass QR code" />
      {err && <p className="error">{err}</p>}

      {r && !r.found && <div className="verdict bad">NOT VALID. Do not let the stock through.</div>}
      {r?.found && r.status === 'issued' && <div className="verdict good">VALID. Checked and signed off.</div>}
      {r?.found && r.status === 'used' && (
        <div className="verdict warn">ALREADY USED {r.used_at ? `on ${fmtDate(r.used_at)}` : ''}</div>
      )}
      {r?.found && r.status === 'void' && <div className="verdict bad">VOIDED. Do not let the stock through.</div>}
      {released && <p className="ok">Pass marked as used.</p>}

      {r?.found && (
        <div className="card">
          <p><strong>{r.pass_number}</strong> · {TYPE[r.type]} · {r.movement_ref}</p>
          {r.counterparty && <p>{r.counterparty}</p>}
          {r.delivery_address && <p>Deliver to: {r.delivery_address}</p>}
          {r.edited && <p className="muted">Details were amended after the note was issued. This is the current version.</p>}
          {r.vehicle_reg && <p>Vehicle {r.vehicle_reg}</p>}
          {r.driver_name && <p>Driver {r.driver_name}</p>}
          <div className="tablewrap">
            <table>
              <thead><tr><th>SKU</th><th>Item</th><th className="num">Qty</th></tr></thead>
              <tbody>
                {(r.lines || []).map((l) => (
                  <tr key={l.sku}><td>{l.sku}</td><td>{l.name}<SerialList serials={l.serials} /></td><td className="num">{fmtQty(l.qty)} {l.unit}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
          <h3 style={{ marginTop: '1rem' }}>Signed by</h3>
          {(r.signed_by || []).map((s) => (
            <p key={s.label} className="muted">{s.label}: {s.name} · {fmtDate(s.at)}</p>
          ))}
          {r.status === 'issued' && (
            <button onClick={release} disabled={busy}>{busy ? 'Saving…' : 'Mark as passed through the gate'}</button>
          )}
        </div>
      )}
    </>
  )
}
