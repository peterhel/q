// Caches the shell so the app opens offline; the queue itself always goes to the server.
const SHELL = "q-shell-1", FILES = ["./", "index.html", "manifest.json", "icon.svg"];
self.addEventListener("install", e => e.waitUntil(caches.open(SHELL).then(c => c.addAll(FILES))));
self.addEventListener("activate", e => e.waitUntil(caches.keys().then(ks =>
  Promise.all(ks.filter(k => k !== SHELL).map(k => caches.delete(k))))));
self.addEventListener("fetch", e => {
  if (new URL(e.request.url).origin !== location.origin) return;
  e.respondWith(fetch(e.request).catch(() => caches.match(e.request)));
});
