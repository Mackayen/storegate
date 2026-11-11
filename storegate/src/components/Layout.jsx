import { useEffect, useState } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import { supabase } from '../supabase.js'
import { useAuth } from '../auth.jsx'
import { PREPARERS, roleName } from '../fmt.js'

export default function Layout() {
  const { profile, session, signOut } = useAuth()
  const [unread, setUnread] = useState(0)
  const uid = session.user.id
  const role = profile.role

  useEffect(() => {
    let off = false
    const load = async () => {
      const { count } = await supabase
        .from('notifications')
        .select('id', { count: 'exact', head: true })
        .eq('read', false)
      if (!off) setUnread(count || 0)
    }
    load()
    const channel = supabase
      .channel('notifications-' + uid)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: 'notifications', filter: `user_id=eq.${uid}` },
        load,
      )
      .subscribe()
    return () => {
      off = true
      supabase.removeChannel(channel)
    }
  }, [uid])

  return (
    <div className="shell">
      <header className="top no-print">
        <div className="brand">StoreGate</div>
        <nav>
          <NavLink to="/" end>Stock</NavLink>
          <NavLink to="/search">Search</NavLink>
          <NavLink to="/movements" end>Movements</NavLink>
          {PREPARERS.includes(role) && <NavLink to="/movements/new">New</NavLink>}
          {['admin', 'security'].includes(role) && <NavLink to="/gate">Gate</NavLink>}
          <NavLink to="/ledger">History</NavLink>
          <NavLink to="/notifications">Alerts{unread > 0 && <span className="count">{unread}</span>}</NavLink>
          <NavLink to="/profile">Profile</NavLink>
          {role === 'admin' && <NavLink to="/admin">Admin</NavLink>}
        </nav>
        <div className="who">
          <span>{profile.full_name} · {roleName(role)}</span>
          <button className="link" onClick={signOut}>Sign out</button>
        </div>
      </header>
      <main>
        <Outlet />
      </main>
    </div>
  )
}
