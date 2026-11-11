const { chromium } = require('playwright')
const BASE = 'http://localhost:4173'
const ok = (n, p, x = '') => console.log((p ? 'PASS' : 'FAIL') + '  ' + n + (x ? '  [' + x + ']' : ''))
const items = [
  { id: 'i1', sku: 'BOLT-10', barcode: '6001', name: 'Bolt M10', unit: 'ea', tracks_serials: false },
  { id: 'i3', sku: 'WASH-1', barcode: '8001', name: 'Washer', unit: 'ea', tracks_serials: false },
]
const state = { status: 'signed_off', address: '1 Old Road', vehicle: 'CA1', edits: [] }
function movement() {
  return { id: 'm1', ref: 'MV-1', type: 'dispatch', status: state.status, created_by: 'u1', created_at: new Date().toISOString(),
    from_storeroom_id: 's1', to_storeroom_id: null, src: { code: 'MAIN', name: 'Main store' }, dest: null, creator: { full_name: 'Sam' },
    counterparty: 'Cust Ltd', delivery_address: state.address, vehicle_reg: state.vehicle, driver_name: 'Dan', notes: null,
    content_hash: 'abcdef0123456789abcdef', steps_snapshot: [], lines: [{ qty: 2, item_id: 'i1', item: { id: 'i1', sku: 'BOLT-10', name: 'Bolt M10', unit: 'ea' } }], serials: [],
    signoffs: [], edits: state.edits, delivery_note: [{ number: 'DN-1' }], gate_pass: [] }
}
async function as(role, fn) {
  const browser = await chromium.launch()
  const ctx = await browser.newContext({ viewport: { width: 900, height: 1000 } })
  const page = await ctx.newPage()
  const errors = [], calls = []
  page.on('pageerror', (e) => { errors.push(e.message); console.log('PAGEERR', e.message) })
  page.on('console', (m) => { if (m.type() === 'error' && !/WebSocket|ERR_|Failed to load/.test(m.text())) console.log('CONSOLE', m.text().slice(0, 200)) })
  await ctx.route('**/example.supabase.co/**', async (route) => {
    const url = route.request().url()
    const json = (b, s = 200) => route.fulfill({ status: s, contentType: 'application/json', headers: { 'content-range': '0-0/0' }, body: JSON.stringify(b) })
    const body = () => JSON.parse(route.request().postData() || '{}')
    if (url.includes('/rest/v1/profiles')) return json({ id: 'u1', full_name: 'Sam', role, active: true })
    if (url.includes('/rest/v1/items')) return json(items)
    if (url.includes('/rest/v1/storerooms')) return json([{ id: 's1', code: 'MAIN', name: 'Main store' }])
    if (url.includes('/rest/v1/delivery_notes')) return json({ number: 'DN-1', issued_at: new Date().toISOString(), snapshot: { type: 'dispatch', movement_ref: 'MV-1', from: { code: 'MAIN', name: 'Main store' }, counterparty: 'SNAPVAL', vehicle_reg: 'SNAPVAL', prepared_by: 'Sam', content_hash: 'oldhash', lines: [{ sku: 'BOLT-10', name: 'Bolt M10', unit: 'ea', qty: 2, serials: [] }] }, movement: movement() })
    if (url.includes('/rest/v1/movements')) { const m = movement(); if (state.status === 'draft') m.lines = [{ qty: 2, item_id: 'i1', item: { id: 'i1', sku: 'BOLT-10', name: 'Bolt M10', unit: 'ea' } }]; return json(m) }
    if (url.includes('/rest/v1/stock_levels') || url.includes('/rest/v1/stock_units')) return json([])
    if (url.includes('/rpc/update_movement_details')) { const b = body(); calls.push(['details', b]); state.edits.push({ id: state.edits.length + 1, at: new Date().toISOString(), kind: 'details', changes: { delivery_address: { from: state.address, to: b.p_address } }, actor: { full_name: 'Sam' } }); state.address = b.p_address; state.vehicle = b.p_vehicle; return json(null) }
    if (url.includes('/rpc/edit_draft_items')) { calls.push(['items', body()]); return json(null) }
    if (url.includes('/auth/v1')) return json({}, 400)
    return json([])
  })
  await page.goto(BASE + '/login')
  const exp = Math.floor(Date.now() / 1000) + 3600
  await page.evaluate(([exp]) => localStorage.setItem('sb-example-auth-token', JSON.stringify({ access_token: 'x.y.z', refresh_token: 'r', token_type: 'bearer', expires_in: 3600, expires_at: exp, user: { id: 'u1', email: 't@x.test', aud: 'authenticated', role: 'authenticated' } })), [exp])
  await fn(page, calls)
  ok(role + ': no JS errors', errors.length === 0, errors.join(' | '))
  await browser.close()
}
;(async () => {
  await as('storeman', async (page, calls) => {
    await page.goto(BASE + '/movements/m1'); await page.waitForSelector('h1:has-text("MV-1")')
    ok('detail: shows the delivery address', await page.locator('text=1 Old Road').count() === 1)
    ok('detail: Edit details is offered after sign off', await page.locator('button:has-text("Edit details")').count() === 1)
    ok('detail: Edit items is not offered after sign off', await page.locator('button:has-text("Edit items")').count() === 0)
    await page.click('button:has-text("Edit details")')
    ok('detail: form is pre filled', (await page.inputValue('#e-ad')) === '1 Old Road' && (await page.inputValue('#e-ve')) === 'CA1')
    ok('detail: says items are locked', await page.locator('text=locked because they are signed').count() === 1)
    await page.fill('#e-ad', '9 New Street'); await page.fill('#e-ve', 'CA999'); await page.click('.modal button:has-text("Save")'); await page.waitForTimeout(400)
    ok('detail: sends all fields', calls[0] && calls[0][1].p_address === '9 New Street' && calls[0][1].p_vehicle === 'CA999' && calls[0][1].p_counterparty === 'Cust Ltd' && calls[0][1].p_id === 'm1', JSON.stringify(calls[0] && calls[0][1]))
    ok('detail: shows the new address after saving', await page.locator('text=9 New Street').count() >= 1 && await page.locator('.modal').count() === 0)
    await page.goto(BASE + '/movements/m1/delivery-note'); await page.waitForSelector('h1:has-text("Delivery note")')
    ok('note: shows live details, not the old snapshot', await page.locator('th:has-text("Delivery address") + td:has-text("9 New Street")').count() === 1 && await page.locator('td:has-text("SNAPVAL")').count() === 0)
    ok('note: lists the amendment with who and old/new', await page.locator('h2:has-text("Amendments")').count() === 1 && await page.locator('text=1 Old Road → 9 New Street').count() === 1)
    ok('note: items still come from what was issued', await page.locator('td:has-text("BOLT-10")').count() === 1)
    ok('note: integrity code is the current one', await page.locator('text=Integrity code abcdef0123456789').count() === 1)
    await page.click('button:has-text("Edit details")'); await page.waitForSelector('#e-ad')
    ok('note: Edit details button opens the editor', (await page.inputValue('#e-ad')) === '9 New Street')
  })
  await as('viewer', async (page) => {
    await page.goto(BASE + '/movements/m1'); await page.waitForSelector('h1:has-text("MV-1")')
    ok('viewer: no edit buttons', await page.locator('button:has-text("Edit details"), button:has-text("Edit items")').count() === 0)
    await page.goto(BASE + '/movements/m1/delivery-note'); await page.waitForSelector('h1:has-text("Delivery note")')
    ok('viewer: no edit button on the note', await page.locator('button:has-text("Edit details")').count() === 0)
  })
  state.status = 'draft'
  await as('storeman', async (page, calls) => {
    await page.goto(BASE + '/movements/m1'); await page.waitForSelector('h1:has-text("MV-1")')
    ok('draft: Edit items is offered to the creator', await page.locator('button:has-text("Edit items")').count() === 1)
    await page.click('button:has-text("Edit items")'); await page.waitForSelector('h1:has-text("Edit draft")')
    await page.waitForSelector('input[aria-label="Quantity for BOLT-10"]')
    ok('edit draft: existing line loaded with its quantity', (await page.inputValue('input[aria-label="Quantity for BOLT-10"]')) === '2')
    ok('edit draft: type and storerooms are locked', await page.locator('#type').isDisabled() && await page.locator('#from').isDisabled())
    ok('edit draft: details loaded', (await page.inputValue('#addr')) === '1 Old Road' || (await page.inputValue('#addr')) === '9 New Street')
    await page.fill('input[aria-label="Quantity for BOLT-10"]', '5')
    await page.selectOption('select[aria-label="Pick an item"]', 'i3'); await page.click('button:has-text("Add")')
    await page.click('button:has-text("Save changes")'); await page.waitForTimeout(500)
    const it = calls.find((c) => c[0] === 'items')
    ok('edit draft: sends the new line list', it && JSON.stringify(it[1]) === JSON.stringify({ p_id: 'm1', p_lines: [{ item_id: 'i1', qty: 5 }, { item_id: 'i3', qty: 1 }] }), JSON.stringify(it && it[1]))
    ok('edit draft: also saves the details', calls.some((c) => c[0] === 'details'))
    ok('edit draft: returns to the movement', page.url().endsWith('/movements/m1'), page.url())
  })
  state.status = 'pending_signoff'
  await as('storeman', async (page) => {
    await page.goto(BASE + '/movements/m1/edit'); await page.waitForSelector('h1:has-text("Edit draft")'); await page.waitForTimeout(500)
    ok('edit draft: refused once submitted', await page.locator('text=only be changed while the movement is a draft').count() === 1)
  })
})()
