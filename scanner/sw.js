// Cache the app shell so it runs with no network at all -- the venues may
// have none. See the offline invariants in CLAUDE.md.
//
// The cache name carries a build stamp. Browsers only install a new service
// worker when this file changes byte-for-byte, so without the stamp every
// phone that had ever loaded the app stayed pinned to the first version it
// saw, forever. tools/build_site.sh replaces __BUILD__ with a hash of the
// files at publish time; run straight from the repo it is a literal and the
// app still works, it just never invalidates.
const CACHE = "attendance-__BUILD__";
const SHELL = ["./", "./index.html", "./jsQR.min.js", "./manifest.json", "./icon.svg"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", e => {
  e.waitUntil(caches.keys()
    .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET") return;               // never touch uploads
  if (url.origin !== location.origin) return;           // Supabase goes straight out
  if (url.pathname.endsWith("codes.csv")) return;       // always the live list
  if (url.pathname.endsWith("config.json")) return;     // server details, never stale

  // Stale-while-revalidate: answer from cache immediately so a queue never
  // waits on the network, but refresh the copy in the background so the next
  // open of the app is current. If there is no network the cache stands.
  e.respondWith(caches.match(e.request).then(hit => {
    const refresh = fetch(e.request).then(res => {
      if (res.ok) caches.open(CACHE).then(c => c.put(e.request, res.clone()));
      return res;
    }).catch(() => hit || new Response("Offline", { status: 503 }));
    return hit || refresh;
  }));
});
