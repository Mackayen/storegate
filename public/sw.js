// Minimal service worker so the app can be installed on a phone or laptop.
// It deliberately caches nothing: stock and sign off data must always come live from Supabase.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))
self.addEventListener('fetch', () => {})
