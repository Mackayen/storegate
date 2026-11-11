const { chromium } = require('playwright')
const BASE = 'http://localhost:4173'
const ok = (n, p, x = '') => console.log((p ? 'PASS' : 'FAIL') + '  ' + n + (x ? '  [' + x + ']' : ''))
const items = [
  { id: 'i1', sku: 'BOLT-10', barcode: '6001', name: 'Bolt M10', unit: 'ea', tracks_serials: false },
  { id: 'i2', sku: 'LAP-1', barcode: '7001', name: 'Lenovo ThinkPad', unit: 'ea', tracks_serials: true },
]
const piles = [
  { storeroom_id: 's1', storeroom_code: 'MAIN', storeroom_name: 'Main store', item_id: 'i2', sku: 'LAP-1', item_name: 'Lenovo ThinkPad', unit: 'ea', tracks_serials: true, qty: 10, serialised: 3, damaged: 1, unassigned: 7 },
  { storeroom_id: 's1', storeroom_code: 'MAIN', storeroom_name: 'Main store', item_id: 'i1', sku: 'BOLT-10', item_name: 'Bolt M10', unit: 'ea', tracks_serials: false, qty: 50, serialised: 0, damaged: 0, unassigned: 0 },
]
const units = [
  { unit_id: 'u1', serial: 'SN-001', status: 'in_stock', damaged: false, note: null, item_id: 'i2', sku: 'LAP-1', item_name: 'Lenovo ThinkPad', storeroom_id: 's1', storeroom_code: 'MAIN', storeroom_name: 'Main store', replaces_unit_id: null, replaced: false },
  { unit_id: 'u2', serial: 'SN-002', status: 'in_stock', damaged: true, note: 'Cracked screen', item_id: 'i2', sku: 'LAP-1', item_name: 'Lenovo ThinkPad', storeroom_id: 's1', storeroom_code: 'MAIN', storeroom_name: 'Main store', replaces_unit_id: null, replaced: false },
]
async function session(role) {
  const browser = await chromium.launch()
  const ctx = await browser.newContext({ viewport: { width: 900, height: 900 } })
  const page = await ctx.newPage()
  const errors = [], calls = []
  page.on('pageerror', (e) => errors.push(e.message))
  page.on('console', (m) => { if (m.type() === 'error' && !/WebSocket|ERR_|Failed to load resource/.test(m.text())) errors.push(m.text()) })
  await ctx.route('**/example.supabase.co/**', async (route) => {
    const url = route.request().url()
    const json = (b, s = 200) => route.fulfill({ status: s, contentType: 'application/json', headers: { 'content-range': '0-0/0' }, body: JSON.stringify(b) })
    const body = () => JSON.parse(route.request().postData() || '{}')
    if (url.includes('/rest/v1/profiles')) return json({ id: 'u1', full_name: 'Test User', role, active: true })
    if (url.includes('/rest/v1/items')) return json(items)
    if (url.includes('/rest/v1/storerooms')) return json([{ id: 's1', code: 'MAIN', name: 'Main store' }])
    if (url.includes('/rest/v1/stock_units')) return json(url.includes('select=item_id%2Cserial') ? [{ item_id: 'i2', serial: 'SN-001' }, { item_id: 'i2', serial: 'SN-003' }] : { id: 'u2', serial: 'SN-002', status: 'in_stock', damaged: true, note: 'Cracked screen', item: { sku: 'LAP-1', name: 'Lenovo ThinkPad' }, storeroom: { code: 'MAIN', name: 'Main store' }, replaces: null })
    if (url.includes('/rest/v1/unit_events')) return json([{ id: 2, at: new Date().toISOString(), kind: 'damaged', note: 'Cracked screen', actor: { full_name: 'Sam' }, movement: null }, { id: 1, at: new Date().toISOString(), kind: 'received', note: null, actor: { full_name: 'Sam' }, movement: { id: 'm1', ref: 'MV-1' } }])
    if (url.includes('/rest/v1/stock_levels')) return json([])
    if (url.includes('/rpc/stock_piles')) return json(piles)
    if (url.includes('/rpc/stock_units_search')) { calls.push(['search', body()]); return json(units) }
    if (url.includes('/rpc/create_movement')) { calls.push(['create', body()]); return json('m9') }
    if (url.includes('/rpc/add_serials')) { calls.push(['add_serials', body()]); return json(2) }
    if (url.includes('/rpc/write_off_stock')) { calls.push(['write_off_stock', body()]); return json(null) }
    if (url.includes('/rpc/flag_unit')) { calls.push(['flag', body()]); return json(null) }
    if (url.includes('/auth/v1')) return json({}, 400)
    return json([])
  })
  await page.goto(BASE + '/login')
  const exp = Math.floor(Date.now() / 1000) + 3600
  await page.evaluate(([exp]) => localStorage.setItem('sb-example-auth-token', JSON.stringify({ access_token: 'x.y.z', refresh_token: 'r', token_type: 'bearer', expires_in: 3600, expires_at: exp, user: { id: 'u1', email: 't@x.test', aud: 'authenticated', role: 'authenticated' } })), [exp])
  return { browser, page, errors, calls }
}
const scan = async (page, v) => { await page.keyboard.type(v, { delay: 2 }); await page.keyboard.press('Enter'); await page.waitForTimeout(120) }
;(async () => {
  { // dispatch with serial scanning
    const { browser, page, errors, calls } = await session('storeman')
    await page.goto(BASE + '/movements/new'); await page.waitForSelector('text=New movement')
    await page.selectOption('#type', 'dispatch'); await page.selectOption('#from', 's1'); await page.waitForTimeout(300)
    await scan(page, 'SN-001')
    ok('dispatch: scanning a serial adds its item with quantity 1', (await page.inputValue('input[aria-label="Quantity for LAP-1"]')) === '1')
    await scan(page, 'sn-003')
    ok('dispatch: second serial raises quantity to 2 (case insensitive)', (await page.inputValue('input[aria-label="Quantity for LAP-1"]')) === '2')
    ok('dispatch: quantity box is read only', await page.locator('input[aria-label="Quantity for LAP-1"]').getAttribute('readonly') !== null)
    await scan(page, 'SN-001')
    ok('dispatch: the same serial twice is refused', await page.locator('text=already on this movement').count() === 1)
    await scan(page, 'SN-999')
    ok('dispatch: unknown serial gives a message', await page.locator('text=No active item or serial number').count() === 1)
    await page.fill('input[placeholder="Scan a LAP-1 serial number"]', 'SN-777'); await page.keyboard.press('Enter')
    ok('dispatch: serial typed in the line panel must be in stock', await page.locator('text=is not an undamaged LAP-1 in stock here').count() === 1)
    await page.click('button:has-text("Save as draft")'); await page.waitForTimeout(300)
    const c = calls.find((x) => x[0] === 'create')
    ok('dispatch: payload carries both serials', c && JSON.stringify(c[1].p_lines) === JSON.stringify([{ item_id: 'i2', qty: 2, serials: ['SN-001', 'SN-003'] }]), JSON.stringify(c && c[1].p_lines))
    await page.goto(BASE + '/movements/new'); await page.waitForSelector('text=New movement')
    await page.selectOption('#type', 'dispatch'); await page.selectOption('#from', 's1'); await page.waitForTimeout(300)
    await scan(page, '7001'); await scan(page, 'SN-001')
    await page.selectOption('#type', 'transfer'); await page.waitForTimeout(200)
    ok('dispatch: changing the type clears the serials', await page.locator('.chip').count() === 0)
    ok('dispatch: no JS errors', errors.length === 0, errors.join(' | '))
    await browser.close()
  }
  { // receive with serials
    const { browser, page, errors, calls } = await session('storeman')
    await page.goto(BASE + '/movements/new'); await page.waitForSelector('text=New movement')
    await page.selectOption('#to', 's1'); await scan(page, '7001')
    await page.fill('input[aria-label="Quantity for LAP-1"]', '10')
    await page.fill('input[placeholder="Scan a LAP-1 serial number"]', 'A-1'); await page.keyboard.press('Enter')
    await page.fill('input[placeholder="Scan a LAP-1 serial number"]', 'A-2'); await page.keyboard.press('Enter')
    await page.waitForTimeout(150)
    ok('receive: quantity stays 10 with 2 serials entered', (await page.inputValue('input[aria-label="Quantity for LAP-1"]')) === '10')
    ok('receive: panel says 2 of 10', await page.locator('text=2 of 10').count() === 1)
    await page.click('button:has-text("Save as draft")'); await page.waitForTimeout(300)
    const c = calls.find((x) => x[0] === 'create')
    ok('receive: payload qty 10 with 2 serials', c && JSON.stringify(c[1].p_lines) === JSON.stringify([{ item_id: 'i2', qty: 10, serials: ['A-1', 'A-2'] }]), JSON.stringify(c && c[1].p_lines))
    ok('receive: no JS errors', errors.length === 0, errors.join(' | '))
    await browser.close()
  }
  { // stock + search for a storeman
    const { browser, page, errors, calls } = await session('storeman')
    await page.goto(BASE); await page.waitForSelector('text=Stock on hand')
    await page.waitForSelector('td:has-text("Lenovo ThinkPad")')
    ok('stock: not working total is shown', await page.locator('.bad:has-text("1 not working")').count() === 1)
    ok('stock: pile with a damaged unit is highlighted', await page.locator('tr.damaged').count() === 1)
    await page.goto(BASE + '/search?q=%25%27%3B%20drop'); await page.waitForSelector('text=Search stock'); await page.waitForTimeout(500)
    const s = calls.filter((x) => x[0] === 'search').pop()
    ok('search: input goes to the database as a bound parameter', s && s[1].p_query === "%'; drop", JSON.stringify(s && s[1]))
    ok('search: damaged unit row is red', await page.locator('tr.damaged:has-text("SN-002")').count() === 1)
    ok('search: damaged unit shows Not working badge', await page.locator('.badge.damaged:has-text("Not working")').count() >= 1)
    ok('search: storeman has pile actions', await page.locator('button:has-text("Add serial numbers")').count() === 1 && await page.locator('button:has-text("Write off")').count() === 2)
    await page.click('button:has-text("Add serial numbers")')
    await page.locator('.modal input[aria-label="Scan input"]').fill('Z-1'); await page.keyboard.press('Enter')
    await page.locator('.modal input[aria-label="Scan input"]').fill('Z-2'); await page.keyboard.press('Enter')
    await page.click('button:has-text("Save 2")'); await page.waitForTimeout(300)
    const a = calls.find((x) => x[0] === 'add_serials')
    ok('search: add serials sends the list', a && JSON.stringify(a[1]) === JSON.stringify({ p_storeroom: 's1', p_item: 'i2', p_serials: ['Z-1', 'Z-2'] }), JSON.stringify(a && a[1]))
    await page.locator('tr:has-text("BOLT-10") button:has-text("Write off")').click()
    await page.fill('#wq', '2'); await page.fill('#wr', 'Rusted'); await page.click('.modal button:has-text("Write off")'); await page.waitForTimeout(300)
    const w = calls.find((x) => x[0] === 'write_off_stock')
    ok('search: write off sends quantity and reason', w && w[1].p_qty === 2 && w[1].p_reason === 'Rusted' && w[1].p_item === 'i1', JSON.stringify(w && w[1]))
    await page.goto(BASE + '/units/u2'); await page.waitForSelector('h1:has-text("SN-002")')
    ok('unit: history lists events', await page.locator('td:has-text("Flagged not working")').count() === 1 && await page.locator('td a:has-text("MV-1")').count() === 1)
    await page.click('button:has-text("Mark as working")'); await page.waitForTimeout(200)
    ok('unit: a note is required before marking working', await page.locator('text=Write a note first').count() === 1)
    await page.fill('#un', 'Fixed'); await page.click('button:has-text("Mark as working")'); await page.waitForTimeout(300)
    const f = calls.find((x) => x[0] === 'flag')
    ok('unit: flag call carries note', f && f[1].p_damaged === false && f[1].p_note === 'Fixed', JSON.stringify(f && f[1]))
    ok('stock: no JS errors', errors.length === 0, errors.join(' | '))
    await browser.close()
  }
  { // viewer sees no actions
    const { browser, page, errors } = await session('viewer')
    await page.goto(BASE + '/search'); await page.waitForSelector('text=Search stock'); await page.waitForTimeout(500)
    ok('viewer: no write off or serial buttons', await page.locator('button:has-text("Write off"), button:has-text("Add serial numbers")').count() === 0)
    await page.goto(BASE + '/units/u2'); await page.waitForSelector('h1:has-text("SN-002")')
    ok('viewer: no update panel on a unit', await page.locator('text=Update this unit').count() === 0)
    ok('viewer: no JS errors', errors.length === 0, errors.join(' | '))
    await browser.close()
  }
  { // admin items tick
    const { browser, page, errors } = await session('admin')
    await page.goto(BASE + '/admin'); await page.waitForSelector('text=Admin')
    await page.click('button:has-text("Items")').catch(() => {})
    ok('admin: serial tick present on new item form', await page.locator('text=Each unit has its own serial number').count() === 1)
    ok('admin: no JS errors', errors.length === 0, errors.join(' | '))
    await browser.close()
  }
})()
