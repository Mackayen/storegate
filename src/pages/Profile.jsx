import { useCallback, useEffect, useRef, useState } from 'react'
import SignaturePad from 'signature_pad'
import { supabase } from '../supabase.js'
import { useAuth } from '../auth.jsx'
import SignatureImg from '../components/SignatureImg.jsx'
import { pinMessage, roleName } from '../fmt.js'

export default function Profile() {
  const { profile, session } = useAuth()
  const uid = session.user.id
  const canvasRef = useRef(null)
  const padRef = useRef(null)
  const [status, setStatus] = useState(null)
  const [current, setCurrent] = useState(null)
  const [sigMsg, setSigMsg] = useState('')
  const [pinMsg, setPinMsg] = useState('')
  const [oldPin, setOldPin] = useState('')
  const [newPin, setNewPin] = useState('')
  const [again, setAgain] = useState('')
  const [busy, setBusy] = useState(false)

  const refresh = useCallback(async () => {
    const [s, sig] = await Promise.all([
      supabase.rpc('my_security_status'),
      supabase.from('user_signatures').select('storage_path').eq('active', true).maybeSingle(),
    ])
    setStatus(s.data || null)
    setCurrent(sig.data?.storage_path || null)
  }, [])

  useEffect(() => {
    refresh()
  }, [refresh])

  useEffect(() => {
    const canvas = canvasRef.current
    const pad = new SignaturePad(canvas, { penColor: '#111827', minWidth: 0.8, maxWidth: 2.4 })
    padRef.current = pad
    let lastWidth = 0
    function resize() {
      if (canvas.offsetWidth === lastWidth) return
      lastWidth = canvas.offsetWidth
      const ratio = Math.max(window.devicePixelRatio || 1, 1)
      canvas.width = canvas.offsetWidth * ratio
      canvas.height = canvas.offsetHeight * ratio
      canvas.getContext('2d').scale(ratio, ratio)
      pad.clear()
    }
    resize()
    window.addEventListener('resize', resize)
    return () => {
      window.removeEventListener('resize', resize)
      pad.off()
    }
  }, [])

  async function saveSignature() {
    setSigMsg('')
    const pad = padRef.current
    if (pad.isEmpty()) return setSigMsg('Draw your signature first.')
    setBusy(true)
    const blob = await new Promise((resolve) => canvasRef.current.toBlob(resolve, 'image/png'))
    if (!blob || blob.size > 200 * 1024) {
      setBusy(false)
      return setSigMsg('The signature is too large. Clear it and sign again, smaller.')
    }
    const path = `${uid}/${crypto.randomUUID()}.png`
    const up = await supabase.storage.from('signatures').upload(path, blob, { contentType: 'image/png', upsert: false })
    if (up.error) {
      setBusy(false)
      return setSigMsg(up.error.message)
    }
    const { error } = await supabase.rpc('save_signature', { p_path: path })
    setBusy(false)
    if (error) return setSigMsg(error.message)
    pad.clear()
    setSigMsg('Signature saved.')
    refresh()
  }

  async function savePin(e) {
    e.preventDefault()
    setPinMsg('')
    if (!/^\d{6}$/.test(newPin)) return setPinMsg('The PIN must be exactly 6 digits.')
    if (newPin !== again) return setPinMsg('The two PINs do not match.')
    setBusy(true)
    const { data, error } = await supabase.rpc('set_pin', { p_new: newPin, p_current: status?.has_pin ? oldPin : null })
    setBusy(false)
    if (error) return setPinMsg(error.message)
    if (!data?.ok) return setPinMsg(pinMessage(data?.error))
    setOldPin('')
    setNewPin('')
    setAgain('')
    setPinMsg('PIN saved.')
    refresh()
  }

  return (
    <>
      <h1>{profile.full_name}</h1>
      <p className="muted">Role: {roleName(profile.role)}</p>

      <div className="card">
        <h3>Signature</h3>
        <p className="muted">
          Draw it once. It is stamped on documents each time you sign with your PIN. Saving a new one replaces the old one for future documents; past documents keep the signature you used.
        </p>
        {current && <p>Current signature: <SignatureImg path={current} height={56} /></p>}
        {!current && status && <p className="error">No signature saved yet. You cannot sign until you add one.</p>}
        <canvas ref={canvasRef} className="sigpad" />
        <div className="row" style={{ marginTop: '.5rem' }}>
          <button className="secondary" onClick={() => padRef.current.clear()}>Clear</button>
          <button onClick={saveSignature} disabled={busy}>Save signature</button>
        </div>
        {sigMsg && <p className={sigMsg === 'Signature saved.' ? 'ok' : 'error'}>{sigMsg}</p>}
      </div>

      <form className="card" onSubmit={savePin}>
        <h3>{status?.has_pin ? 'Change PIN' : 'Set PIN'}</h3>
        <p className="muted">Six digits. Five wrong attempts lock signing for 15 minutes.</p>
        {status?.has_pin && (
          <>
            <label htmlFor="old">Current PIN</label>
            <input id="old" type="password" inputMode="numeric" maxLength={6} autoComplete="off" value={oldPin} onChange={(e) => setOldPin(e.target.value.replace(/\D/g, ''))} />
          </>
        )}
        <label htmlFor="new">New PIN</label>
        <input id="new" type="password" inputMode="numeric" maxLength={6} autoComplete="new-password" value={newPin} onChange={(e) => setNewPin(e.target.value.replace(/\D/g, ''))} />
        <label htmlFor="again">Repeat new PIN</label>
        <input id="again" type="password" inputMode="numeric" maxLength={6} autoComplete="new-password" value={again} onChange={(e) => setAgain(e.target.value.replace(/\D/g, ''))} />
        <p><button type="submit" disabled={busy}>Save PIN</button></p>
        {pinMsg && <p className={pinMsg === 'PIN saved.' ? 'ok' : 'error'}>{pinMsg}</p>}
      </form>
    </>
  )
}
