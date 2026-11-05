import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { supabase } from '../supabase.js'
import { useAuth } from '../auth.jsx'
import PinDialog from '../components/PinDialog.jsx'
import SignatureImg from '../components/SignatureImg.jsx'
import SerialList from '../components/SerialList.jsx'
import { STATUS, TYPE, fmtDate, fmtQty, one, pinMessage, roleName } from '../fmt.js'

const SELECT =
  '*, src:storerooms!from_storeroom_id(code, name), dest:storerooms!to_storeroom_id(code, name), creator:profiles!created_by(full_name), ' +
  'lines:movement_lines(qty, item:items(id, sku, name, unit)), serials:movement_serials(item_id, serial), ' +
  'signoffs(step_order, step_label, role, signed_at, signature_path, user_id, user:profiles!user_id(full_name)), ' +
  'delivery_note:delivery_notes(number), gate_pass:gate_passes(number, status)'

export default function MovementDetail() {
  const { id } = useParams()
  const { profile, session } = useAuth()
  const uid = session.user.id
  const [m, setM] = useState(null)
  const [err, setErr] = useState('')
  const [pinMode, setPinMode] = useState(null)
  const [rejecting, setRejecting] = useState(false)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    const { data, error } = await supabase.from('movements').select(SELECT).eq('id', id).maybeSingle()
    if (error) setErr(error.message)
    else if (!data) setErr('Movement not found.')
    else {
      setErr('')
      setM(data)
    }
  }, [id])

  useEffect(() => {
    load()
    const channel = supabase
      .channel('movement-' + id)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'movements', filter: `id=eq.${id}` }, load)
      .subscribe()
    return () => supabase.removeChannel(channel)
  }, [id, load])

  if (err && !m) return <p className="error">{err}</p>
  if (!m) return <p className="center">Loading…</p>

  const steps = [{ order: 0, role: 'storeman', label: 'Prepared by' }, ...(m.steps_snapshot || [])]
  const signed = new Map((m.signoffs || []).map((s) => [s.step_order, s]))
  const next = m.status === 'pending_signoff' ? steps.find((s) => !signed.has(s.order)) : null
  const iSigned = (m.signoffs || []).some((s) => s.user_id === uid)
  const canSign = next && next.role === profile.role && !iSigned
  const isCreator = m.created_by === uid
  const canCancel = (isCreator || profile.role === 'admin') && ['draft', 'pending_signoff'].includes(m.status)
  const dn = one(m.delivery_note)
  const gp = one(m.gate_pass)

  async function runPin(pin) {
    const fn = pinMode === 'submit' ? 'submit_movement' : 'sign_movement'
    const { data, error } = await supabase.rpc(fn, { p_id: id, p_pin: pin })
    if (error) return error.message
    if (!data?.ok) return pinMessage(data?.error)
    setPinMode(null)
    await load()
    return null
  }

  async function reject() {
    setBusy(true)
    const { error } = await supabase.rpc('reject_movement', { p_id: id, p_reason: reason })
    setBusy(false)
    if (error) return setErr(error.message)
    setRejecting(false)
    setReason('')
    load()
  }

  async function cancel() {
    if (!window.confirm('Cancel this movement?')) return
    setBusy(true)
    const { error } = await supabase.rpc('cancel_movement', { p_id: id, p_reason: 'Cancelled' })
    setBusy(false)
    if (error) setErr(error.message)
    else load()
  }

  return (
    <>
      <div className="row spread">
        <h1>{m.ref}</h1>
        <span className={`badge ${m.status}`}>{STATUS[m.status]}</span>
      </div>

      <div className="card">
        <div className="grid2">
          <div><span className="muted">Type</span><div>{TYPE[m.type]}</div></div>
          {m.src && <div><span className="muted">From</span><div>{m.src.code} · {m.src.name}</div></div>}
          {m.dest && <div><span className="muted">To</span><div>{m.dest.code} · {m.dest.name}</div></div>}
          {m.counterparty && <div><span className="muted">Supplier / customer</span><div>{m.counterparty}</div></div>}
          {m.vehicle_reg && <div><span className="muted">Vehicle</span><div>{m.vehicle_reg}</div></div>}
          {m.driver_name && <div><span className="muted">Driver</span><div>{m.driver_name}</div></div>}
          <div><span className="muted">Created by</span><div>{m.creator?.full_name}</div></div>
          <div><span className="muted">Created</span><div>{fmtDate(m.created_at)}</div></div>
        </div>
        {m.notes && <p>{m.notes}</p>}
        {m.rejection_reason && <p className="error">Reason: {m.rejection_reason}</p>}
      </div>

      <div className="card tablewrap">
        <table>
          <thead><tr><th>SKU</th><th>Item</th><th className="num">Qty</th></tr></thead>
          <tbody>
            {[...(m.lines || [])].sort((a, b) => a.item.sku.localeCompare(b.item.sku)).map((l) => (
              <tr key={l.item.sku}><td>{l.item.sku}</td><td>{l.item.name}<SerialList serials={(m.serials || []).filter((x) => x.item_id === l.item.id).map((x) => x.serial).sort()} /></td><td className="num">{fmtQty(l.qty)} {l.item.unit}</td></tr>
            ))}
          </tbody>
        </table>
      </div>

      {m.status !== 'draft' && (
        <div className="card">
          <h3>Sign off</h3>
          <ul className="steps">
            {steps.map((s) => {
              const so = signed.get(s.order)
              const isNext = next && next.order === s.order
              return (
                <li key={s.order}>
                  <span className={`dot ${so ? 'done' : isNext ? 'next' : ''}`} />
                  <div style={{ flex: 1 }}>
                    <strong>{s.label}</strong>
                    <div className="muted">
                      {so ? `${so.user?.full_name} · ${fmtDate(so.signed_at)}` : `Waiting for ${roleName(s.role)}`}
                    </div>
                  </div>
                  {so && <SignatureImg path={so.signature_path} />}
                </li>
              )
            })}
          </ul>
        </div>
      )}

      {err && <p className="error">{err}</p>}

      <div className="row no-print">
        {m.status === 'draft' && isCreator && <button onClick={() => setPinMode('submit')}>Submit and sign</button>}
        {canSign && <button onClick={() => setPinMode('sign')}>Sign off</button>}
        {canSign && <button className="danger" onClick={() => setRejecting(true)}>Reject</button>}
        {canCancel && <button className="secondary" onClick={cancel} disabled={busy}>Cancel movement</button>}
        {dn && <Link to={`/movements/${id}/delivery-note`}><button className="secondary">Delivery note {dn.number}</button></Link>}
        {gp && <Link to={`/movements/${id}/gate-pass`}><button className="secondary">Gate pass {gp.number}</button></Link>}
      </div>

      {rejecting && (
        <div className="card" style={{ marginTop: '1rem' }}>
          <label htmlFor="reason">Reason for rejecting</label>
          <textarea id="reason" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={500} />
          <div className="row" style={{ marginTop: '.5rem' }}>
            <button className="danger" onClick={reject} disabled={busy || reason.trim().length < 3}>Confirm reject</button>
            <button className="secondary" onClick={() => setRejecting(false)}>Back</button>
          </div>
        </div>
      )}

      {pinMode && (
        <PinDialog
          title={pinMode === 'submit' ? 'Submit and sign' : 'Sign off'}
          onSubmit={runPin}
          onClose={() => setPinMode(null)}
        />
      )}
    </>
  )
}
