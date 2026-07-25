// Hakhagi Service Worker — offline cache untuk static assets
const CACHE = 'hakhagi-v1'
const ASSETS = [
  '/',
  '/styles/app.css',
  '/manifest.json'
]

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE).then(cache => cache.addAll(ASSETS))
  )
  self.skipWaiting()
})

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(
      keys.filter(k => k !== CACHE).map(k => caches.delete(k))
    ))
  )
  self.clients.claim()
})

// Network-first: coba fetch, fallback ke cache
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url)
  // Only cache GET, same-origin requests
  if (e.request.method !== 'GET' || !url.origin.startsWith(self.location.origin)) return

  e.respondWith(
    fetch(e.request)
      .then(res => {
        const clone = res.clone()
        caches.open(CACHE).then(cache => cache.put(e.request, clone))
        return res
      })
      .catch(() => caches.match(e.request))
  )
})
