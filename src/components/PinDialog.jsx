import { useState } from 'react'

// onSubmit(pin) must resolve to an error message, or null when it worked.
export default function PinDialog({ title, onSubmit, onClose }) {
  const [pin, setPin] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  async function go(e) {
    e.preventDefault()
    if (!/^\d{6}$/.test(pin)) {
      setErr('Enter your 6 digit PIN.')
      return
    }
    setBusy(true)
    const message = await onSubmit(pin)
    setBusy(false)
    if (message) {
      setErr(message)
      setPin('')
    }
  }

  return (
    <div className="modal" role="dialog" aria-modal="true" aria-label={title}>
      <form className="card" onSubmit={go}>
        <h3>{title}</h3>
        <p className="muted">Enter your PIN to sign. Your saved signature is added to the document.</p>
        <input
          type="password"
          inputMode="numeric"
          autoComplete="off"
          maxLength={6}
          value={pin}
          onChange={(e) => setPin(e.target.value.replace(/\D/g, ''))}
          autoFocus
          aria-label="PIN"
        />
        {err && <p className="error">{err}</p>}
        <div className="row">
          <button type="button" className="secondary" onClick={onClose} disabled={busy}>Cancel</button>
          <button type="submit" disabled={busy}>{busy ? 'Signing…' : 'Sign'}</button>
        </div>
      </form>
    </div>
  )
}
