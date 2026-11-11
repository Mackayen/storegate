import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../supabase.js'
import { fmtDate } from '../fmt.js'

export default function Notifications() {
  const [rows, setRows] = useState([])
  const [err, setErr] = useState('')

  const load = useCallback(async () => {
    const { data, error } = await supabase
      .from('notifications')
      .select('id, title, body, movement_id, read, created_at')
      .order('created_at', { ascending: false })
      .limit(100)
    if (error) setErr(error.message)
    else setRows(data)
  }, [])

  useEffect(() => {
    load()
  }, [load])

  async function markRead(id) {
    await supabase.from('notifications').update({ read: true }).eq('id', id)
    load()
  }

  async function markAll() {
    await supabase.from('notifications').update({ read: true }).eq('read', false)
    load()
  }

  return (
    <>
      <div className="row spread">
        <h1>Alerts</h1>
        {rows.some((r) => !r.read) && <button className="secondary" onClick={markAll}>Mark all as read</button>}
      </div>
      {err && <p className="error">{err}</p>}
      {rows.map((n) => (
        <div key={n.id} className="card">
          <div className={n.read ? '' : 'unread'}>{n.title}</div>
          <div>{n.body}</div>
          <div className="row spread">
            <span className="muted">{fmtDate(n.created_at)}</span>
            <span className="row">
              {n.movement_id && <Link to={`/movements/${n.movement_id}`} onClick={() => !n.read && markRead(n.id)}>Open</Link>}
              {!n.read && <button className="secondary" onClick={() => markRead(n.id)}>Mark as read</button>}
            </span>
          </div>
        </div>
      ))}
      {rows.length === 0 && <p className="muted">No alerts yet.</p>}
    </>
  )
}
