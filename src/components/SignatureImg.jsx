import { useEffect, useState } from 'react'
import { supabase } from '../supabase.js'

// Signatures live in a private bucket, so they are downloaded with the user's session.
export default function SignatureImg({ path, height = 44 }) {
  const [url, setUrl] = useState(null)

  useEffect(() => {
    let off = false
    let objectUrl = null
    if (!path) return undefined
    supabase.storage
      .from('signatures')
      .download(path)
      .then(({ data }) => {
        if (data && !off) {
          objectUrl = URL.createObjectURL(data)
          setUrl(objectUrl)
        }
      })
    return () => {
      off = true
      if (objectUrl) URL.revokeObjectURL(objectUrl)
    }
  }, [path])

  return url ? <img className="sig" src={url} alt="Signature" style={{ height }} /> : <span className="muted">…</span>
}
