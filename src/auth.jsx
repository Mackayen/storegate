import { createContext, useContext, useEffect, useState } from 'react'
import { supabase } from './supabase.js'

const Ctx = createContext(null)
export const useAuth = () => useContext(Ctx)

export function AuthProvider({ children }) {
  const [session, setSession] = useState(null)
  const [profile, setProfile] = useState(null)
  const [loading, setLoading] = useState(true)
  const [authError, setAuthError] = useState('')

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      if (!data.session) setLoading(false)
    })
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s)
      if (!s) {
        setProfile(null)
        setLoading(false)
      }
    })
    return () => sub.subscription.unsubscribe()
  }, [])

  const uid = session?.user?.id

  useEffect(() => {
    if (!uid) return
    let cancelled = false
    supabase
      .from('profiles')
      .select('id, full_name, role, active')
      .eq('id', uid)
      .maybeSingle()
      .then(({ data, error }) => {
        if (cancelled) return
        if (error || !data || !data.active) {
          setAuthError('This account is not active. Contact an administrator.')
          setProfile(null)
          supabase.auth.signOut()
        } else {
          setAuthError('')
          setProfile(data)
        }
        setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [uid])

  const value = {
    session,
    profile,
    loading,
    authError,
    clearAuthError: () => setAuthError(''),
    signOut: () => supabase.auth.signOut(),
  }
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}
