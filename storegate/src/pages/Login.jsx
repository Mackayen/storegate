import { useState } from 'react'
import { Navigate } from 'react-router-dom'
import { supabase } from '../supabase.js'
import { useAuth } from '../auth.jsx'

export default function Login() {
  const { session, profile, loading, authError, clearAuthError } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [err, setErr] = useState('')
  const [busy, setBusy] = useState(false)

  if (!loading && session && profile) return <Navigate to="/" replace />

  async function submit(e) {
    e.preventDefault()
    setBusy(true)
    setErr('')
    clearAuthError()
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    setBusy(false)
    // One generic message so the form does not reveal which emails exist.
    if (error) setErr('Incorrect email or password.')
  }

  return (
    <main style={{ maxWidth: 380 }}>
      <h1 style={{ textAlign: 'center', marginTop: '3rem' }}>StoreGate</h1>
      <form className="card" onSubmit={submit}>
        <label htmlFor="email">Email</label>
        <input id="email" type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />
        <label htmlFor="password">Password</label>
        <input id="password" type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />
        {(err || authError) && <p className="error">{err || authError}</p>}
        <p>
          <button type="submit" disabled={busy} style={{ width: '100%' }}>{busy ? 'Signing in…' : 'Sign in'}</button>
        </p>
        <p className="muted">Accounts are created by an administrator. There is no public sign up.</p>
      </form>
    </main>
  )
}
