// Sends an email for every new row in public.notifications.
// Trigger it with a Database Webhook (Database > Webhooks) on INSERT into notifications,
// with the HTTP header  x-webhook-secret: <WEBHOOK_SECRET>.
// Deploy with: supabase functions deploy notify-email --no-verify-jwt
// (the shared secret below is the authentication, not a user JWT)
//
// Secrets to set: WEBHOOK_SECRET, RESEND_API_KEY, FROM_EMAIL, APP_URL
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!))

function safeEqual(a: string, b: string) {
  if (a.length !== b.length) return false
  let r = 0
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return r === 0
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 })

  const secret = Deno.env.get('WEBHOOK_SECRET') ?? ''
  const given = req.headers.get('x-webhook-secret') ?? ''
  if (!secret || !safeEqual(secret, given)) return new Response('Unauthorized', { status: 401 })

  const payload = await req.json().catch(() => null)
  const rec = payload?.record
  if (payload?.type !== 'INSERT' || payload?.table !== 'notifications' || !rec?.user_id) {
    return new Response('Ignored', { status: 200 })
  }

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data, error } = await admin.auth.admin.getUserById(rec.user_id)
  const to = data?.user?.email
  if (error || !to) return new Response('No recipient', { status: 200 })

  const appUrl = (Deno.env.get('APP_URL') ?? '').replace(/\/$/, '')
  const link = appUrl && rec.movement_id ? `${appUrl}/movements/${rec.movement_id}` : appUrl
  const html =
    `<p>${esc(String(rec.body ?? rec.title ?? ''))}</p>` +
    (link ? `<p><a href="${esc(link)}">Open in StoreGate</a></p>` : '')

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${Deno.env.get('RESEND_API_KEY')}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: Deno.env.get('FROM_EMAIL'),
      to: [to],
      subject: `StoreGate: ${String(rec.title ?? 'Notification').slice(0, 120)}`,
      html,
    }),
  })
  return new Response(res.ok ? 'sent' : 'send failed', { status: res.ok ? 200 : 502 })
})
