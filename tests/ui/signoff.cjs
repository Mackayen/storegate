const { chromium } = require('playwright')
const BASE = 'http://localhost:4173'
const ok = (n, p, x = '') => console.log((p ? 'PASS' : 'FAIL') + '  ' + n + (x ? '  [' + x + ']' : ''))
const steps = [{ order: 1, role: 'dispatch_manager', label: 'Dispatch manager check' }, { order: 2, role: 'procurement', label: 'Procurement approval' }]
// one shared fake database for the whole flow
const db = { status: 'draft', signoffs: [], created_by: 'u-sam', pin: { 'u-sam': '111111', 'u-dm': '222222', 'u-pr': '333333' } }
const names = { 'u-sam': 'Sam Storeman', 'u-dm': 'Dee Dispatch', 'u-pr': 'Pat Procurement' }
function movement() {
  return { id: 'm1', ref: 'MV-2026-000001', type: 'dispatch', status: db.status, created_by: db.created_by, created_at: new Date().toISOString(),
    src: { code: 'MAIN', name: 'Main store' }, dest: null, creator: { full_name: names['u-sam'] }, counterparty: 'Cust', notes: null,
    steps_snapshot: db.status === 'draft' ? null : steps,
    lines: [{ qty: 2, item: { id: 'i2', sku: 'LAP-1', name: 'Laptop', unit: 'ea' } }], serials: [{ item_id: 'i2', serial: 'SN-1' }, { item_id: 'i2', serial: 'SN-2' }],
    signoffs: db.signoffs.map((s) => ({ ...s, user: { full_name: names[s.user_id] } })),
    delivery_note: db.status === 'draft' ? [] : [{ number: 'DN-1' }], gate_pass: db.status === 'signed_off' ? [{ number: 'GP-1', status: 'issued' }] : [] }
}
async function as(uid, role, fn) {
  const browser = await chromium.launch()
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 } })
  const page = await ctx.newPage()
  const errors = []
  page.on('pageerror', (e) => errors.push(e.message))
  await ctx.route('**/example.supabase.co/**', async (route) => {
    const url = route.request().url()
    const json = (b, s = 200) => route.fulfill({ status: s, contentType: 'application/json', headers: { 'content-range': '0-0/0' }, body: JSON.stringify(b) })
    const body = () => JSON.parse(route.request().postData() || '{}')
    if (url.includes('/rest/v1/profiles')) return json({ id: uid, full_name: names[uid], role, active: true })
    if (url.includes('/rest/v1/movements')) return json(movement())
    if (url.includes('/rpc/submit_movement') || url.includes('/rpc/sign_movement')) {
      const b = body(); const submit = url.includes('submit')
      if (b.p_pin !== db.pin[uid]) return json({ ok: false, error: 'wrong' })
      if (submit) { db.status = 'pending_signoff'; db.signoffs.push({ step_order: 0, step_label: 'Prepared by', role, user_id: uid, signed_at: new Date().toISOString(), signature_path: 'x' }); return json({ ok: true }) }
      const next = steps.find((s) => !db.signoffs.some((x) => x.step_order === s.order))
      if (!next || next.role !== role) return json({ message: 'needs the ' + next?.role }, 400)
      db.signoffs.push({ step_order: next.order, step_label: next.label, role, user_id: uid, signed_at: new Date().toISOString(), signature_path: 'x' })
      const done = db.signoffs.length === 3; if (done) db.status = 'signed_off'
      return json({ ok: true, completed: done })
    }
    if (url.includes('/auth/v1')) return json({}, 400)
    return json([])
  })
  await page.goto(BASE + '/login')
  const exp = Math.floor(Date.now() / 1000) + 3600
  await page.evaluate(([exp, uid]) => localStorage.setItem('sb-example-auth-token', JSON.stringify({ access_token: 'x.y.z', refresh_token: 'r', token_type: 'bearer', expires_in: 3600, expires_at: exp, user: { id: uid, email: 't@x.test', aud: 'authenticated', role: 'authenticated' } })), [exp, uid])
  await page.goto(BASE + '/movements/m1'); await page.waitForSelector('h1:has-text("MV-2026-000001")')
  await fn(page)
  ok(role + ': no JS errors', errors.length === 0, errors.join(' | '))
  await browser.close()
}
const pin = async (page, v) => { await page.fill('input[aria-label="PIN"]', v); await page.keyboard.press('Enter'); await page.waitForTimeout(400) }
;(async () => {
  await as('u-sam', 'storeman', async (page) => {
    ok('storeman: draft shows Submit and sign, no Sign off', await page.locator('button:has-text("Submit and sign")').count() === 1 && await page.locator('button:has-text("Sign off")').count() === 0)
    await page.click('button:has-text("Submit and sign")'); await pin(page, '12')
    ok('storeman: short PIN is rejected before sending', await page.locator('text=Enter your 6 digit PIN').count() === 1)
    await pin(page, '999999'); await page.fill('input[aria-label="PIN"]', '')
    ok('storeman: wrong PIN gives a message and the dialog stays', await page.locator('text=Incorrect PIN').count() === 1)
    await pin(page, '111111')
    ok('storeman: submit works, status Awaiting sign off', await page.locator('.badge:has-text("Awaiting sign off")').count() === 1)
    ok('storeman: prepared by step is signed', await page.locator('text=Sam Storeman ·').count() >= 1)
    ok('storeman: delivery note link appears', await page.locator('button:has-text("Delivery note DN-1")').count() === 1)
    ok('storeman: serials visible on the movement', await page.locator('text=SN-1, SN-2').count() === 1)
    ok('storeman: cannot sign the next step', await page.locator('button:has-text("Sign off")').count() === 0)
  })
  await as('u-pr', 'procurement', async (page) => {
    ok('procurement: cannot sign before the dispatch manager', await page.locator('button:has-text("Sign off")').count() === 0)
  })
  await as('u-dm', 'dispatch_manager', async (page) => {
    ok('dispatch manager: sees Sign off and Reject', await page.locator('button:has-text("Sign off")').count() === 1 && await page.locator('button:has-text("Reject")').count() === 1)
    await page.click('button:has-text("Sign off")'); await pin(page, '111111')
    ok('dispatch manager: wrong PIN refused', await page.locator('text=Incorrect PIN').count() === 1)
    await pin(page, '222222')
    ok('dispatch manager: signed, still awaiting', await page.locator('.badge:has-text("Awaiting sign off")').count() === 1 && await page.locator('button:has-text("Sign off")').count() === 0)
  })
  await as('u-pr', 'procurement', async (page) => {
    ok('procurement: now sees Sign off', await page.locator('button:has-text("Sign off")').count() === 1)
    await page.click('button:has-text("Sign off")'); await pin(page, '333333')
    ok('procurement: movement is Signed off', await page.locator('.badge:has-text("Signed off")').count() === 1)
    ok('procurement: gate pass link appears', await page.locator('button:has-text("Gate pass GP-1")').count() === 1)
    ok('procurement: all three signatures listed', await page.locator('.steps li .dot.done').count() === 3)
  })
})()
