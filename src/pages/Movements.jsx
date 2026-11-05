import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { supabase } from '../supabase.js'
import { useAuth } from '../auth.jsx'
import { PREPARERS, STATUS, TYPE, fmtDate } from '../fmt.js'

export default function Movements() {
  const { profile } = useAuth()
  const [rows, setRows] = useState([])
  const [status, setStatus] = useState('')
  const [err, setErr] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let off = false
    async function load() {
      let query = supabase
        .from('movements')
        .select('id, ref, type, status, counterparty, created_at, src:storerooms!from_storeroom_id(code), dest:storerooms!to_storeroom_id(code), creator:profiles!created_by(full_name)')
        .order('created_at', { ascending: false })
        .limit(200)
      if (status) query = query.eq('status', status)
      const { data, error } = await query
      if (off) return
      if (error) setErr(error.message)
      else {
        setErr('')
        setRows(data)
      }
      setLoading(false)
    }
    load()
    const channel = supabase
      .channel('movements-list')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'movements' }, load)
      .subscribe()
    return () => {
      off = true
      supabase.removeChannel(channel)
    }
  }, [status])

  return (
    <>
      <div className="row spread">
        <h1>Movements</h1>
        {PREPARERS.includes(profile.role) && <Link to="/movements/new"><button>New movement</button></Link>}
      </div>
      <div className="card">
        <label htmlFor="status">Status</label>
        <select id="status" value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="">All</option>
          {Object.entries(STATUS).map(([k, v]) => (
            <option key={k} value={k}>{v}</option>
          ))}
        </select>
      </div>
      {err && <p className="error">{err}</p>}
      <div className="card tablewrap">
        <table>
          <thead>
            <tr><th>Ref</th><th>Type</th><th>From / to</th><th>Status</th><th>Created</th></tr>
          </thead>
          <tbody>
            {rows.map((m) => (
              <tr key={m.id}>
                <td><Link to={`/movements/${m.id}`}>{m.ref}</Link></td>
                <td>{TYPE[m.type]}</td>
                <td>
                  {m.src?.code || m.counterparty || '—'} → {m.dest?.code || m.counterparty || '—'}
                </td>
                <td><span className={`badge ${m.status}`}>{STATUS[m.status]}</span></td>
                <td>{fmtDate(m.created_at)}<div className="muted">{m.creator?.full_name}</div></td>
              </tr>
            ))}
            {!loading && rows.length === 0 && <tr><td colSpan={5} className="muted">No movements yet.</td></tr>}
          </tbody>
        </table>
      </div>
    </>
  )
}
