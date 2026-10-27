// Service Worker HARIZMA ONLINE: agar bisa diinstal & cepat dibuka.
// Data Supabase TIDAK pernah disimpan di cache (selalu diambil langsung dari server).
const V = 'harizma-v2';
const SHELL = ['./', 'index.html', 'config.js', 'manifest.json', 'icon-192.png', 'icon-512.png'];
self.addEventListener('install', e => e.waitUntil(
  caches.open(V).then(c => Promise.all(SHELL.map(u => c.add(u).catch(() => {})))).then(() => self.skipWaiting())));
self.addEventListener('activate', e => e.waitUntil(
  caches.keys().then(k => Promise.all(k.filter(x => x !== V).map(x => caches.delete(x)))).then(() => clients.claim())));
const simpan = (r, res) => { if (res.ok) { const cp = res.clone(); caches.open(V).then(c => c.put(r, cp)); } return res; };
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.hostname.endsWith('supabase.co')) return;       // data: langsung ke jaringan
  if (u.origin === location.origin)                                            // berkas aplikasi: jaringan dulu, cadangan dari cache
    e.respondWith(fetch(r).then(res => simpan(r, res)).catch(() => caches.match(r).then(m => m || caches.match('index.html'))));
  else if (u.hostname === 'cdn.jsdelivr.net')                                  // pustaka supabase-js: cache dulu
    e.respondWith(caches.match(r).then(m => m || fetch(r).then(res => simpan(r, res))));
});
