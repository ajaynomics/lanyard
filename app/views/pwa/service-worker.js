// Installable and honest offline: pages always come from the network (a
// conversation is never served stale), and only a failed navigation gets a
// small offline page. Live updates (Action Cable) and forms never touch this.
const OFFLINE = new Response(
  "<!doctype html><meta name=viewport content='width=device-width'><title>Offline</title>" +
  "<body style='font-family:system-ui;padding:2rem'><h1>You are offline</h1><p>Avery needs a connection. Try again when you are back online.</p>",
  { headers: { "Content-Type": "text/html; charset=utf-8" } }
)

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))

self.addEventListener("fetch", event => {
  if (event.request.mode !== "navigate") return
  event.respondWith(fetch(event.request).catch(() => OFFLINE.clone()))
})
